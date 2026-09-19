/*
 * wschan.c - WebSockets for Tcl in a browser.
 *
 * Tcl reaches the network through `socket`, and a wasm build has none: there
 * are no sockets in a page, only the two protocols the browser speaks on a
 * script's behalf. For XMPP that is a WebSocket (RFC 7395), so this gives Tcl
 * one:
 *
 *   ::wschan::open url ?-protocols list? -command prefix   -> id
 *   ::wschan::send id text
 *   ::wschan::state id          connecting | open | closing | closed
 *   ::wschan::close id ?code? ?reason?
 *   ::wschan::destroy id
 *
 * and calls the prefix back with one event appended:
 *
 *   open | message text | close code reason | error message
 *
 * A socket rather than a Tcl channel: RFC 7395 is defined in terms of message
 * boundaries - one frame is one XML element - and a channel is a byte stream,
 * so a channel would destroy the boundaries and leave the caller to parse
 * them back.
 *
 * Events arrive through emqueue.c, which says why a JavaScript callback
 * cannot call into the interpreter directly. One consequence shows up here:
 * emscripten_websocket_set_onmessage_callback hands a *C* callback to
 * JavaScript, so this file does not use that API. Every handler below stays
 * in JavaScript. Only the inbound direction inverts - a send is an ordinary
 * call out of wasm, made while Tcl is running.
 */

#include <emscripten.h>
#include <stdlib.h>
#include <string.h>
#include <tcl.h>

#include "emqueue.h"
#include "wschan.h"

#define WSCHAN_STATE "__wschan"

/* -- the JavaScript side --------------------------------------------------
 *
 * globalThis.__wschan holds the sockets and the queue.
 */

EM_JS(int, ws_js_open, (const char *url, const char *protocols), {
    if (typeof WebSocket === 'undefined') {
        return -1;
    }
    if (!globalThis.__wschan) {
        globalThis.__wschan = { next: 1, socks: {}, queue: [] };
    }
    const st = globalThis.__wschan;
    const address = UTF8ToString(url);
    const subprotocols = UTF8ToString(protocols);
    let sock;
    try {
        sock = subprotocols
            ? new WebSocket(address, subprotocols.split(','))
            : new WebSocket(address);
    } catch (err) {
        return -1;
    }
    const id = st.next++;
    st.socks[id] = sock;
    sock.binaryType = 'arraybuffer';
    sock.onopen = () => st.queue.push([id, "open"]);
    sock.onmessage = (ev) => {
        // RFC 7395 is a text subprotocol, but a peer may still send a binary
        // frame; it is UTF-8 either way, and XML is what has to come out.
        const text = typeof ev.data === 'string'
            ? ev.data
            : new TextDecoder().decode(new Uint8Array(ev.data));
        st.queue.push([id, "message", text]);
    };
    sock.onclose = (ev) => st.queue.push([id, "close", String(ev.code), ev.reason || ""]);
    // The error event carries nothing by design (it would leak cross-origin
    // detail); the close that follows it says whether anything was lost.
    sock.onerror = () => st.queue.push([id, "error", "websocket error"]);
    return id;
});

EM_JS(int, ws_js_send, (int id, const char *text), {
    const sock = globalThis.__wschan?.socks[id];
    if (!sock || sock.readyState !== WebSocket.OPEN) {
        return 1;
    }
    try {
        sock.send(UTF8ToString(text));
    } catch (err) {
        return 1;
    }
    return 0;
});

/* WebSocket.readyState, or -1 for a socket this process does not have. */
EM_JS(int, ws_js_state, (int id), {
    const sock = globalThis.__wschan?.socks[id];
    return sock ? sock.readyState : -1;
});

EM_JS(void, ws_js_close, (int id, int code, const char *reason), {
    const sock = globalThis.__wschan?.socks[id];
    if (!sock || sock.readyState > WebSocket.OPEN) {
        return;
    }
    try {
        sock.close(code, UTF8ToString(reason));
    } catch (err) {
        // A bad code or an over-long reason: the socket still has to go.
        sock.close();
    }
});

EM_JS(void, ws_js_delete, (int id), {
    const st = globalThis.__wschan;
    const sock = st?.socks[id];
    if (!sock) {
        return;
    }
    sock.onopen = sock.onmessage = sock.onclose = sock.onerror = null;
    try { sock.close(); } catch (err) { /* already gone */ }
    delete st.socks[id];
    st.queue = st.queue.filter((ev) => ev[0] !== id);
});

/* -- the sockets Tcl knows about ------------------------------------------ */

typedef struct WsSock {
    int id;
    Tcl_Interp *interp;
    Tcl_Obj *command;       /* the -command prefix, reference held */
    struct WsSock *next;
} WsSock;

static WsSock *sockets = NULL;

static void Drain(void *clientData);

static WsSock *
SockFind(int id)
{
    WsSock *s;

    for (s = sockets; s != NULL; s = s->next) {
        if (s->id == id) {
            return s;
        }
    }
    return NULL;
}

static void
SockForget(int id)
{
    WsSock **pp, *s;

    for (pp = &sockets; *pp != NULL; pp = &(*pp)->next) {
        if ((*pp)->id == id) {
            s = *pp;
            *pp = s->next;
            Tcl_DecrRefCount(s->command);
            ckfree(s);
            if (sockets == NULL) {
                EmQueue_Unwatch(Drain, NULL);
            }
            return;
        }
    }
}

/*
 * Hand the queued events to their sockets' -command. A handler may do
 * anything a Tcl command may do, this socket's destruction included, so the
 * record is looked up again for every event and never held across one.
 */
static void
Drain(void *clientData)
{
    char *event;

    (void)clientData;
    while ((event = EmQueue_Poll(WSCHAN_STATE)) != NULL) {
        char *fields[4];
        /*
         * Three, not four: every kind but close ends in free-form text, and
         * the last field is the one that keeps its separators. close alone
         * has a field after its code, so it splits once more.
         */
        int n = EmQueue_Split(event, fields, 3);
        WsSock *s = n >= 2 ? SockFind((int)strtol(fields[0], NULL, 10)) : NULL;

        if (n == 3 && strcmp(fields[1], "close") == 0) {
            n = 2 + EmQueue_Split(fields[2], fields + 2, 2);
        }
        if (s != NULL) {
            EmQueue_Dispatch(s->interp, s->command, n - 1, fields + 1);
        }
        free(event);
    }
}

/* -- the commands ---------------------------------------------------------- */

static int
WsOpenCmd(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[])
{
    Tcl_Obj *command = NULL, *protocols = NULL;
    Tcl_DString joined;
    WsSock *s;
    int i, id;

    (void)cd;
    if (objc < 2 || (objc % 2) != 0) {
        Tcl_WrongNumArgs(ip, 1, objv, "url ?-protocols list? -command prefix");
        return TCL_ERROR;
    }
    for (i = 2; i < objc; i += 2) {
        const char *opt = Tcl_GetString(objv[i]);

        if (strcmp(opt, "-command") == 0) {
            command = objv[i + 1];
        } else if (strcmp(opt, "-protocols") == 0) {
            protocols = objv[i + 1];
        } else {
            Tcl_SetObjResult(ip, Tcl_ObjPrintf(
                "bad option \"%s\": must be -command or -protocols", opt));
            return TCL_ERROR;
        }
    }
    if (command == NULL || Tcl_GetCharLength(command) == 0) {
        Tcl_SetResult(ip, "a websocket needs a -command to report to", TCL_STATIC);
        return TCL_ERROR;
    }

    /* A Tcl list of subprotocol names; the browser wants them comma-joined. */
    Tcl_DStringInit(&joined);
    if (protocols != NULL) {
        Tcl_Obj **names;
        Tcl_Size nNames;

        if (Tcl_ListObjGetElements(ip, protocols, &nNames, &names) != TCL_OK) {
            Tcl_DStringFree(&joined);
            return TCL_ERROR;
        }
        for (Tcl_Size k = 0; k < nNames; k++) {
            if (k > 0) {
                Tcl_DStringAppend(&joined, ",", 1);
            }
            Tcl_DStringAppend(&joined, Tcl_GetString(names[k]), -1);
        }
    }
    id = ws_js_open(Tcl_GetString(objv[1]), Tcl_DStringValue(&joined));
    Tcl_DStringFree(&joined);
    if (id < 0) {
        Tcl_SetObjResult(ip, Tcl_ObjPrintf("cannot open %s", Tcl_GetString(objv[1])));
        return TCL_ERROR;
    }

    s = (WsSock *)ckalloc(sizeof *s);
    s->id = id;
    s->interp = ip;
    s->command = command;
    Tcl_IncrRefCount(s->command);
    s->next = sockets;
    sockets = s;
    EmQueue_Watch(Drain, NULL);

    Tcl_SetObjResult(ip, Tcl_NewIntObj(id));
    return TCL_OK;
}

/* The socket named by objv[1], or NULL with an error left in the interp. */
static WsSock *
SockArg(Tcl_Interp *ip, Tcl_Obj *idObj)
{
    WsSock *s;
    int id;

    if (Tcl_GetIntFromObj(ip, idObj, &id) != TCL_OK) {
        return NULL;
    }
    s = SockFind(id);
    if (s == NULL) {
        Tcl_SetObjResult(ip, Tcl_ObjPrintf("no such websocket: %d", id));
    }
    return s;
}

static int
WsSendCmd(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[])
{
    WsSock *s;

    (void)cd;
    if (objc != 3) {
        Tcl_WrongNumArgs(ip, 1, objv, "id text");
        return TCL_ERROR;
    }
    if ((s = SockArg(ip, objv[1])) == NULL) {
        return TCL_ERROR;
    }
    if (ws_js_send(s->id, Tcl_GetString(objv[2])) != 0) {
        Tcl_SetObjResult(ip, Tcl_ObjPrintf("websocket %d is not open", s->id));
        return TCL_ERROR;
    }
    return TCL_OK;
}

static int
WsStateCmd(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[])
{
    static const char *const names[] = { "connecting", "open", "closing", "closed" };
    WsSock *s;
    int state;

    (void)cd;
    if (objc != 2) {
        Tcl_WrongNumArgs(ip, 1, objv, "id");
        return TCL_ERROR;
    }
    if ((s = SockArg(ip, objv[1])) == NULL) {
        return TCL_ERROR;
    }
    state = ws_js_state(s->id);
    Tcl_SetResult(ip, (char *)(state >= 0 && state <= 3 ? names[state] : "closed"),
        TCL_STATIC);
    return TCL_OK;
}

static int
WsCloseCmd(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[])
{
    WsSock *s;
    int code = 1000;    /* "normal closure" */

    (void)cd;
    if (objc < 2 || objc > 4) {
        Tcl_WrongNumArgs(ip, 1, objv, "id ?code? ?reason?");
        return TCL_ERROR;
    }
    if ((s = SockArg(ip, objv[1])) == NULL) {
        return TCL_ERROR;
    }
    if (objc > 2 && Tcl_GetIntFromObj(ip, objv[2], &code) != TCL_OK) {
        return TCL_ERROR;
    }
    ws_js_close(s->id, code, objc > 3 ? Tcl_GetString(objv[3]) : "");
    return TCL_OK;
}

static int
WsDestroyCmd(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[])
{
    WsSock *s;

    (void)cd;
    if (objc != 2) {
        Tcl_WrongNumArgs(ip, 1, objv, "id");
        return TCL_ERROR;
    }
    if ((s = SockArg(ip, objv[1])) == NULL) {
        return TCL_ERROR;
    }
    ws_js_delete(s->id);
    SockForget(s->id);
    return TCL_OK;
}

int
Wschan_Init(Tcl_Interp *interp)
{
    if (Tcl_CreateNamespace(interp, "::wschan", NULL, NULL) == NULL) {
        return TCL_ERROR;
    }
    Tcl_CreateObjCommand(interp, "::wschan::open", WsOpenCmd, NULL, NULL);
    Tcl_CreateObjCommand(interp, "::wschan::send", WsSendCmd, NULL, NULL);
    Tcl_CreateObjCommand(interp, "::wschan::state", WsStateCmd, NULL, NULL);
    Tcl_CreateObjCommand(interp, "::wschan::close", WsCloseCmd, NULL, NULL);
    Tcl_CreateObjCommand(interp, "::wschan::destroy", WsDestroyCmd, NULL, NULL);
    /* Its existence is the capability test; a build without this file has no
     * ::wschan at all, and a caller asking for the transport finds that out
     * rather than silently getting something else. */
    Tcl_SetVar2Ex(interp, "::wschan::available", NULL, Tcl_NewBooleanObj(1),
        TCL_GLOBAL_ONLY);
    return Tcl_PkgProvide(interp, "wschan", "0.1");
}

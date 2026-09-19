/*
 * httpx.c - HTTP for Tcl in a browser.
 *
 * Tcl's http package speaks HTTP over a socket, and a page has neither. Its
 * own HTTP stack does TLS, redirects, cookies, CORS and HTTP/2, and is the
 * only thing a page may make a request through, so this is a binding rather
 * than a client:
 *
 *   ::httpx::request method url ?-outfile path? ?-infile path?
 *                    ?-headers dict? ?-timeout ms?
 *                    ?-command prefix? ?-progress prefix?    -> id
 *   ::httpx::status id      "" while in flight, then ok | error | timeout | reset
 *   ::httpx::ncode id       the HTTP status code, 0 if there never was one
 *   ::httpx::error id       why it failed, "" otherwise
 *   ::httpx::abort id
 *   ::httpx::cleanup id
 *
 * -command is called with the id once the request has settled; -progress with
 * `id total current`, which is the shape Tcl's http package uses so a caller
 * can hand the same procedure to either.
 *
 * Bodies move through Emscripten's filesystem rather than through Tcl
 * channels: JavaScript can read and write a file there (FS.readFile /
 * FS.writeFile) and cannot write into a Tcl channel at all. A caller names a
 * path and the bytes are at that path when -command fires.
 *
 * XMLHttpRequest rather than fetch, for upload progress: fetch reports none
 * without duplex request streams. Where there is no XHR - node, where the
 * tests run - it falls back to fetch, which still reports download progress
 * off the response stream; an upload there reports one step at the end.
 *
 * Events come back through emqueue.c.
 */

#include <emscripten.h>
#include <stdlib.h>
#include <string.h>
#include <tcl.h>

#include "emqueue.h"
#include "httpx.h"

#define HTTPX_STATE "__httpx"

/* -- the JavaScript side -------------------------------------------------- */

/*
 * headers is name and value alternating, US-separated, as emqueue packs
 * everything. Returns the request id; a request that cannot even start still
 * gets one, with its failure already in the queue, so the caller has one
 * shape to handle rather than two.
 */
EM_JS(int, httpx_js_request, (const char *method, const char *url,
        const char *outfile, const char *infile, const char *headers,
        int timeout), {
    if (!globalThis.__httpx) {
        globalThis.__httpx = { next: 1, reqs: {}, queue: [] };
    }
    const st = globalThis.__httpx;
    const id = st.next++;
    const verb = UTF8ToString(method);
    const address = UTF8ToString(url);
    const out = UTF8ToString(outfile);
    const from = UTF8ToString(infile);
    const packed = UTF8ToString(headers);
    const pairs = packed ? packed.split("\x1f") : [];
    const settle = (status, code, error) => {
        delete st.reqs[id];
        st.queue.push([id, "done", status, String(code), error]);
    };
    const step = (total, loaded) =>
        st.queue.push([id, "progress", String(total || 0), String(loaded || 0)]);

    let body = null;
    if (from) {
        try {
            body = FS.readFile(from);
        } catch (err) {
            settle("error", 0, "cannot read " + from + ": " + err);
            return id;
        }
    }

    if (typeof XMLHttpRequest !== "undefined") {
        const xhr = new XMLHttpRequest();
        st.reqs[id] = xhr;
        try {
            xhr.open(verb, address, true);
        } catch (err) {
            settle("error", 0, String(err));
            return id;
        }
        xhr.responseType = "arraybuffer";
        if (timeout > 0) {
            xhr.timeout = timeout;
        }
        for (let i = 0; i + 1 < pairs.length; i += 2) {
            try { xhr.setRequestHeader(pairs[i], pairs[i + 1]); } catch (err) { /* forbidden */ }
        }
        xhr.onprogress = (ev) => step(ev.total, ev.loaded);
        if (xhr.upload) {
            xhr.upload.onprogress = (ev) => step(ev.total, ev.loaded);
        }
        xhr.onload = () => {
            if (out) {
                try {
                    FS.writeFile(out, new Uint8Array(xhr.response ?? new ArrayBuffer(0)));
                } catch (err) {
                    settle("error", xhr.status, "cannot write " + out + ": " + err);
                    return;
                }
            }
            settle("ok", xhr.status, "");
        };
        // The error event carries nothing by design: a page is not told why
        // a cross-origin request failed.
        xhr.onerror = () => settle("error", xhr.status, "network error");
        xhr.ontimeout = () => settle("timeout", 0, "timed out");
        xhr.onabort = () => settle("reset", 0, "aborted");
        try {
            xhr.send(body);
        } catch (err) {
            settle("error", 0, String(err));
        }
        return id;
    }

    const control = new AbortController();
    st.reqs[id] = control;
    const timer = timeout > 0
        ? setTimeout(() => { control.expired = true; control.abort(); }, timeout)
        : 0;
    (async () => {
        try {
            const head = {};
            for (let i = 0; i + 1 < pairs.length; i += 2) {
                head[pairs[i]] = pairs[i + 1];
            }
            const res = await fetch(address, {
                method: verb, headers: head, body, signal: control.signal,
            });
            const total = Number(res.headers.get("content-length") ?? 0);
            const chunks = [];
            let loaded = 0;
            if (res.body) {
                const reader = res.body.getReader();
                for (;;) {
                    const piece = await reader.read();
                    if (piece.done) break;
                    chunks.push(piece.value);
                    loaded += piece.value.length;
                    step(total, loaded);
                }
            }
            if (out) {
                const all = new Uint8Array(loaded);
                let at = 0;
                for (const chunk of chunks) { all.set(chunk, at); at += chunk.length; }
                FS.writeFile(out, all);
            }
            clearTimeout(timer);
            settle("ok", res.status, "");
        } catch (err) {
            clearTimeout(timer);
            if (control.expired) settle("timeout", 0, "timed out");
            else if (err && err.name === "AbortError") settle("reset", 0, "aborted");
            else settle("error", 0, String((err && err.message) || err));
        }
    })();
    return id;
});

EM_JS(void, httpx_js_abort, (int id), {
    const req = globalThis.__httpx?.reqs[id];
    if (req) {
        try { req.abort(); } catch (err) { /* already finished */ }
    }
});

EM_JS(void, httpx_js_forget, (int id), {
    const st = globalThis.__httpx;
    if (!st) return;
    delete st.reqs[id];
    st.queue = st.queue.filter((ev) => ev[0] !== id);
});

EM_JS(int, httpx_js_available, (void), {
    return (typeof XMLHttpRequest !== "undefined" || typeof fetch !== "undefined") ? 1 : 0;
});

/* -- the requests Tcl knows about ----------------------------------------- */

typedef struct HttpxReq {
    int id;
    Tcl_Interp *interp;
    Tcl_Obj *command;    /* called with the id when it settles */
    Tcl_Obj *progress;   /* called with id, total, current */
    Tcl_Obj *status;     /* "" until it settles */
    Tcl_Obj *error;
    int code;
    struct HttpxReq *next;
} HttpxReq;

static HttpxReq *requests = NULL;

static void Drain(void *clientData);

static HttpxReq *
ReqFind(int id)
{
    HttpxReq *r;

    for (r = requests; r != NULL; r = r->next) {
        if (r->id == id) {
            return r;
        }
    }
    return NULL;
}

static void
ReqForget(int id)
{
    HttpxReq **pp, *r;

    for (pp = &requests; *pp != NULL; pp = &(*pp)->next) {
        if ((*pp)->id == id) {
            r = *pp;
            *pp = r->next;
            if (r->command) Tcl_DecrRefCount(r->command);
            if (r->progress) Tcl_DecrRefCount(r->progress);
            Tcl_DecrRefCount(r->status);
            Tcl_DecrRefCount(r->error);
            ckfree(r);
            if (requests == NULL) {
                EmQueue_Unwatch(Drain, NULL);
            }
            return;
        }
    }
}

static void
Drain(void *clientData)
{
    char *event;

    (void)clientData;
    while ((event = EmQueue_Poll(HTTPX_STATE)) != NULL) {
        char *fields[5];
        int n = EmQueue_Split(event, fields, 5);
        HttpxReq *r = n >= 2 ? ReqFind((int)strtol(fields[0], NULL, 10)) : NULL;

        if (r == NULL) {
            free(event);
            continue; /* cleaned up between the queue and here */
        }
        if (strcmp(fields[1], "progress") == 0 && n >= 4 && r->progress != NULL) {
            char *words[3] = { fields[0], fields[2], fields[3] };

            EmQueue_Dispatch(r->interp, r->progress, 3, words);
        } else if (strcmp(fields[1], "done") == 0 && n >= 5) {
            Tcl_Obj *command = r->command;

            Tcl_DecrRefCount(r->status);
            r->status = Tcl_NewStringObj(fields[2], -1);
            Tcl_IncrRefCount(r->status);
            r->code = (int)strtol(fields[3], NULL, 10);
            Tcl_DecrRefCount(r->error);
            r->error = Tcl_NewStringObj(fields[4], -1);
            Tcl_IncrRefCount(r->error);
            if (command != NULL) {
                /* The handler may call cleanup on this very request, so the
                 * record is not touched again afterwards. */
                EmQueue_Dispatch(r->interp, command, 1, fields);
            }
        }
        free(event);
    }
}

/* -- the commands ---------------------------------------------------------- */

static int
RequestCmd(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[])
{
    Tcl_Obj *command = NULL, *progress = NULL, *headers = NULL;
    const char *outfile = "", *infile = "";
    Tcl_DString packed;
    HttpxReq *r;
    int i, timeout = 0, id;

    (void)cd;
    if (objc < 3 || (objc % 2) == 0) {
        Tcl_WrongNumArgs(ip, 1, objv, "method url ?-option value ...?");
        return TCL_ERROR;
    }
    for (i = 3; i < objc; i += 2) {
        const char *opt = Tcl_GetString(objv[i]);

        if (strcmp(opt, "-command") == 0) {
            command = objv[i + 1];
        } else if (strcmp(opt, "-progress") == 0) {
            progress = objv[i + 1];
        } else if (strcmp(opt, "-outfile") == 0) {
            outfile = Tcl_GetString(objv[i + 1]);
        } else if (strcmp(opt, "-infile") == 0) {
            infile = Tcl_GetString(objv[i + 1]);
        } else if (strcmp(opt, "-headers") == 0) {
            headers = objv[i + 1];
        } else if (strcmp(opt, "-timeout") == 0) {
            if (Tcl_GetIntFromObj(ip, objv[i + 1], &timeout) != TCL_OK) {
                return TCL_ERROR;
            }
        } else {
            Tcl_SetObjResult(ip, Tcl_ObjPrintf("bad option \"%s\": must be"
                " -command, -progress, -outfile, -infile, -headers or -timeout", opt));
            return TCL_ERROR;
        }
    }

    Tcl_DStringInit(&packed);
    if (headers != NULL) {
        Tcl_Obj **words;
        Tcl_Size nWords;

        if (Tcl_ListObjGetElements(ip, headers, &nWords, &words) != TCL_OK) {
            Tcl_DStringFree(&packed);
            return TCL_ERROR;
        }
        if ((nWords % 2) != 0) {
            Tcl_DStringFree(&packed);
            Tcl_SetResult(ip, "-headers takes a dict of header names and values",
                TCL_STATIC);
            return TCL_ERROR;
        }
        for (Tcl_Size k = 0; k < nWords; k++) {
            if (k > 0) {
                Tcl_DStringAppend(&packed, "\x1f", 1);
            }
            Tcl_DStringAppend(&packed, Tcl_GetString(words[k]), -1);
        }
    }
    id = httpx_js_request(Tcl_GetString(objv[1]), Tcl_GetString(objv[2]),
        outfile, infile, Tcl_DStringValue(&packed), timeout);
    Tcl_DStringFree(&packed);
    if (id < 0) {
        Tcl_SetResult(ip, "no HTTP client in this environment", TCL_STATIC);
        return TCL_ERROR;
    }

    r = (HttpxReq *)ckalloc(sizeof *r);
    r->id = id;
    r->interp = ip;
    r->command = command;
    r->progress = progress;
    if (command) Tcl_IncrRefCount(command);
    if (progress) Tcl_IncrRefCount(progress);
    r->status = Tcl_NewObj();
    Tcl_IncrRefCount(r->status);
    r->error = Tcl_NewObj();
    Tcl_IncrRefCount(r->error);
    r->code = 0;
    r->next = requests;
    requests = r;
    EmQueue_Watch(Drain, NULL);

    Tcl_SetObjResult(ip, Tcl_NewIntObj(id));
    return TCL_OK;
}

static HttpxReq *
ReqArg(Tcl_Interp *ip, Tcl_Obj *idObj)
{
    HttpxReq *r;
    int id;

    if (Tcl_GetIntFromObj(ip, idObj, &id) != TCL_OK) {
        return NULL;
    }
    r = ReqFind(id);
    if (r == NULL) {
        Tcl_SetObjResult(ip, Tcl_ObjPrintf("no such request: %d", id));
    }
    return r;
}

static int
QueryCmd(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[])
{
    HttpxReq *r;

    if (objc != 2) {
        Tcl_WrongNumArgs(ip, 1, objv, "id");
        return TCL_ERROR;
    }
    if ((r = ReqArg(ip, objv[1])) == NULL) {
        return TCL_ERROR;
    }
    switch ((int)(intptr_t)cd) {
    case 0: Tcl_SetObjResult(ip, r->status); break;
    case 1: Tcl_SetObjResult(ip, Tcl_NewIntObj(r->code)); break;
    default: Tcl_SetObjResult(ip, r->error); break;
    }
    return TCL_OK;
}

static int
AbortCmd(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[])
{
    HttpxReq *r;

    (void)cd;
    if (objc != 2) {
        Tcl_WrongNumArgs(ip, 1, objv, "id");
        return TCL_ERROR;
    }
    if ((r = ReqArg(ip, objv[1])) == NULL) {
        return TCL_ERROR;
    }
    httpx_js_abort(r->id);
    return TCL_OK;
}

static int
CleanupCmd(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[])
{
    HttpxReq *r;

    (void)cd;
    if (objc != 2) {
        Tcl_WrongNumArgs(ip, 1, objv, "id");
        return TCL_ERROR;
    }
    if ((r = ReqArg(ip, objv[1])) == NULL) {
        return TCL_ERROR;
    }
    httpx_js_forget(r->id);
    ReqForget(r->id);
    return TCL_OK;
}

int
Httpx_Init(Tcl_Interp *interp)
{
    if (Tcl_CreateNamespace(interp, "::httpx", NULL, NULL) == NULL) {
        return TCL_ERROR;
    }
    Tcl_CreateObjCommand(interp, "::httpx::request", RequestCmd, NULL, NULL);
    Tcl_CreateObjCommand(interp, "::httpx::status", QueryCmd, (void *)(intptr_t)0, NULL);
    Tcl_CreateObjCommand(interp, "::httpx::ncode", QueryCmd, (void *)(intptr_t)1, NULL);
    Tcl_CreateObjCommand(interp, "::httpx::error", QueryCmd, (void *)(intptr_t)2, NULL);
    Tcl_CreateObjCommand(interp, "::httpx::abort", AbortCmd, NULL, NULL);
    Tcl_CreateObjCommand(interp, "::httpx::cleanup", CleanupCmd, NULL, NULL);
    Tcl_SetVar2Ex(interp, "::httpx::available", NULL,
        Tcl_NewBooleanObj(httpx_js_available()), TCL_GLOBAL_ONLY);
    return Tcl_PkgProvide(interp, "httpx", "0.1");
}

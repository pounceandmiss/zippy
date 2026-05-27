/* mbedtls override file. Set via -DMBEDTLS_USER_CONFIG_FILE=<this> at
 * mbedtls's CMake configure time. PUBLIC, so find_package consumers
 * inherit it. */

/* DTLS-SRTP (RFC 5764) — libdatachannel's WebRTC media transport needs it. */
#define MBEDTLS_SSL_DTLS_SRTP

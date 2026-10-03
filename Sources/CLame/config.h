/* The configuration of the CLame target for macOS 14 and later, arm64 and x86_64. */
#ifndef LAME_CONFIG_H
#define LAME_CONFIG_H
#define STDC_HEADERS 1
#define HAVE_ERRNO_H 1
#define HAVE_FCNTL_H 1
#define HAVE_LIMITS_H 1
#define HAVE_STDINT_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRING_H 1
#define HAVE_STRINGS_H 1
#define HAVE_UNISTD_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_INT8_T 1
#define HAVE_INT16_T 1
#define HAVE_INT32_T 1
#define HAVE_INT64_T 1
#define HAVE_UINT8_T 1
#define HAVE_UINT16_T 1
#define HAVE_UINT32_T 1
#define HAVE_UINT64_T 1
#define SIZEOF_SHORT 2
#define SIZEOF_INT 4
#define SIZEOF_LONG 8
#define SIZEOF_FLOAT 4
#define SIZEOF_DOUBLE 8
/* No TAKEHIRO_IEEE754_HACK: LAME tests it with #ifdef, so any definition turns it on.
   LAME 3.101 turned it off by default: on current CPUs it is slower. */
#define USE_FAST_LOG 1
#define LAME_LIBRARY_BUILD 1
typedef float ieee754_float32_t;
typedef double ieee754_float64_t;
typedef long double ieee854_float80_t;
#endif

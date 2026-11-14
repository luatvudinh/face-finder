/* Sinh bởi tools/vendor_libjpeg_turbo.sh từ src/jconfigint.h.in của libjpeg-turbo 3.1.4.1. */
#define BUILD  "facefinder"
#define HIDDEN  __attribute__((visibility("hidden")))
#undef inline
#define INLINE  __inline__ __attribute__((always_inline))
#define THREAD_LOCAL  __thread
#define PACKAGE_NAME  "libjpeg-turbo"
#define VERSION  "3.1.4.1"
#define SIZEOF_SIZE_T  8
#define HAVE_BUILTIN_CTZL

#if defined(__has_attribute)
#if __has_attribute(fallthrough)
#define FALLTHROUGH  __attribute__((fallthrough));
#else
#define FALLTHROUGH
#endif
#else
#define FALLTHROUGH
#endif

#ifndef BITS_IN_JSAMPLE
#define BITS_IN_JSAMPLE  8
#endif

#undef C_ARITH_CODING_SUPPORTED
#undef D_ARITH_CODING_SUPPORTED
#undef WITH_SIMD

#if BITS_IN_JSAMPLE == 8
#define D_ARITH_CODING_SUPPORTED  1
#if defined(__aarch64__)
#define WITH_SIMD  1
#endif
#endif

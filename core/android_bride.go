//go:build android && cgo

package main

/*
#cgo LDFLAGS: -ldl
#include <dlfcn.h>
#include <malloc.h>
#include <stdlib.h>

#ifndef M_PURGE
#define M_PURGE (-101)
#endif
#ifndef M_PURGE_ALL
#define M_PURGE_ALL (-104)
#endif

static void purge_memory(void) {
    // The app's minimum Android API predates mallopt.
    int (*set_malloc_option)(int, int) = (int (*)(int, int))dlsym(RTLD_DEFAULT, "mallopt");
    if (set_malloc_option && set_malloc_option(M_PURGE_ALL, 0) != 1) {
        set_malloc_option(M_PURGE, 0);
    }
}

typedef void (*release_object_func)(void *obj);

typedef int (*protect_func)(void *tun_interface, int fd);

typedef const char* (*resolve_process_func)(void *tun_interface, int protocol, const char *source, const char *target, int uid);

static int protect(protect_func fn, void *tun_interface, int fd) {
    if (fn) {
        return fn(tun_interface, fd);
    }
    return 0;
}

static const char* resolve_process(resolve_process_func fn, void *tun_interface, int protocol, const char *source, const char *target, int uid) {
    if (fn) {
        return fn(tun_interface, protocol, source, target, uid);
    }
    return "";
}

static void release_object(release_object_func fn, void *obj) {
    if (fn) {
        return fn(obj);
    }
}
*/
import "C"
import (
	"unsafe"
)

var (
	globalCallbacks struct {
		releaseObjectFunc  C.release_object_func
		protectFunc        C.protect_func
		resolveProcessFunc C.resolve_process_func
	}
)

func purgeNativeMemory() {
	C.purge_memory()
}

func Protect(callback unsafe.Pointer, fd int) bool {
	if globalCallbacks.protectFunc != nil {
		return C.protect(globalCallbacks.protectFunc, callback, C.int(fd)) != 0
	}
	return false
}

func ResolveProcess(callback unsafe.Pointer, protocol int, source, target string, uid int) string {
	if globalCallbacks.resolveProcessFunc == nil {
		return ""
	}
	s := C.CString(source)
	defer C.free(unsafe.Pointer(s))
	t := C.CString(target)
	defer C.free(unsafe.Pointer(t))
	res := C.resolve_process(globalCallbacks.resolveProcessFunc, callback, C.int(protocol), s, t, C.int(uid))
	defer C.free(unsafe.Pointer(res))
	return C.GoString(res)
}

func releaseObject(callback unsafe.Pointer) {
	if globalCallbacks.releaseObjectFunc == nil {
		return
	}
	C.release_object(globalCallbacks.releaseObjectFunc, callback)
}

//export registerCallbacks
func registerCallbacks(markSocketFunc C.protect_func, resolveProcessFunc C.resolve_process_func, releaseObjectFunc C.release_object_func) {
	globalCallbacks.protectFunc = markSocketFunc
	globalCallbacks.resolveProcessFunc = resolveProcessFunc
	globalCallbacks.releaseObjectFunc = releaseObjectFunc
}

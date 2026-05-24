#!/usr/bin/env bash
# Build an OpenSmalltalk/Squeak stack VM for wasm32-posix-kernel.
#
# The stack interpreter is slower than Sista/Cog, but it gets the main Squeak
# 6.0 release image much farther on wasm32 today. The Sista/Cog build reached
# the splash screen but then hit eden/allocation and SmallInteger DNU failures.
set -euo pipefail

SQUEAK_COMMIT="${SQUEAK_COMMIT:-cc2dd909045721f6cbf16cb62f5662fe68158021}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SRC_DIR="$SCRIPT_DIR/opensmalltalk-vm-src"
BUILD_DIR="$SCRIPT_DIR/build"
BIN_DIR="$SCRIPT_DIR/bin"
OPENSSL_DIR="$REPO_ROOT/packages/registry/openssl/openssl-install"
SQUEAK_VM_FLAVOR="${SQUEAK_VM_FLAVOR:-spur}"
SQUEAK_BUILD_SUFFIX="${SQUEAK_BUILD_SUFFIX:-}"
SQUEAK_V3_6502_COMMIT="${SQUEAK_V3_6502_COMMIT:-0888205a0ee171d956fd7c18f4bf7c80d6d651e6}"
SQUEAK_EXTRA_CFLAGS=""

case "$SQUEAK_VM_FLAVOR" in
    spur)
        VM_LABEL="Squeak Spur stack VM"
        VM_SRC_DIR="src/spur32.stack"
        VM_EXTRA_MEMORY_OBJECT="sqUnixSpurMemory.o"
        SQUEAK_PACKAGE_NAME="${SQUEAK_PACKAGE_NAME:-squeak}"
        SQUEAK_OUTPUT_NAME="${SQUEAK_OUTPUT_NAME:-squeak.wasm}"
        ;;
    v3)
        VM_LABEL="Squeak V3 6502 stack VM"
        VM_SRC_DIR="src/v3-6502.stack"
        VM_EXTRA_MEMORY_OBJECT=""
        SQUEAK_PACKAGE_NAME="${SQUEAK_PACKAGE_NAME:-squeak-v3}"
        SQUEAK_OUTPUT_NAME="${SQUEAK_OUTPUT_NAME:-squeak-v3.wasm}"
        [ -n "$SQUEAK_BUILD_SUFFIX" ] || SQUEAK_BUILD_SUFFIX="-v3"
        SQUEAK_EXTRA_CFLAGS="-DBigEndianFloats=1"
        ;;
    *)
        echo "ERROR: unknown SQUEAK_VM_FLAVOR '$SQUEAK_VM_FLAVOR' (expected spur or v3)" >&2
        exit 2
        ;;
esac
BUILD_DIR="$SCRIPT_DIR/build$SQUEAK_BUILD_SUFFIX"
VM_EXECUTABLE="squeak"

source "$REPO_ROOT/sdk/activate.sh"
export PATH="$REPO_ROOT/sdk/bin:$PATH"
if [ -n "${WASM_POSIX_LLVM_DIR:-}" ]; then
    export PATH="$WASM_POSIX_LLVM_DIR:$PATH"
fi
export WASM_POSIX_SYSROOT="$REPO_ROOT/sysroot"
export WASM_POSIX_MAX_MEMORY="${WASM_POSIX_MAX_MEMORY:-4294967296}"
export CONFIG_SITE="$REPO_ROOT/sdk/config.site"

if [ ! -f "$WASM_POSIX_SYSROOT/lib/libc.a" ]; then
    echo "ERROR: sysroot not found. Run: bash scripts/build-musl.sh" >&2
    exit 1
fi
bash "$REPO_ROOT/scripts/install-overlay-headers.sh" "$WASM_POSIX_SYSROOT"
if [ ! -f "$OPENSSL_DIR/lib/libssl.a" ] || [ ! -f "$OPENSSL_DIR/lib/libcrypto.a" ]; then
    echo "==> Building OpenSSL for SqueakSSL..."
    bash "$REPO_ROOT/packages/registry/openssl/build-openssl.sh"
fi

if [ ! -d "$SRC_DIR/.git" ]; then
    echo "==> Cloning OpenSmalltalk VM..."
    git clone --filter=blob:none https://github.com/OpenSmalltalk/opensmalltalk-vm "$SRC_DIR"
fi

cd "$SRC_DIR"
if [ "$(git rev-parse HEAD)" != "$SQUEAK_COMMIT" ]; then
    echo "==> Checking out OpenSmalltalk VM $SQUEAK_COMMIT..."
    git fetch --filter=blob:none origin "$SQUEAK_COMMIT"
    git checkout --force "$SQUEAK_COMMIT"
fi

echo "==> Applying wasm32-posix patches..."
for patch in "$SCRIPT_DIR/patches/"*.patch; do
    [ -f "$patch" ] || continue
    if git apply --recount --check "$patch" >/dev/null 2>&1; then
        git apply --recount "$patch"
    else
        echo "    $(basename "$patch") already applied or superseded"
    fi
done

if ! grep -q KANDELO_INIT_SECURITY_PLUGIN "$SRC_DIR/platforms/unix/vm/sqUnixMain.c"; then
    perl -0pi -e '
        s/imgInit\(\);\n  \/\* If running as a single instance/imgInit();\n#if defined(__wasm32__)\n# define KANDELO_INIT_SECURITY_PLUGIN 1\n  {\n    extern sqInt ioInitSecurity(void);\n    ioInitSecurity();\n  }\n#endif\n  \/* If running as a single instance/;
    ' "$SRC_DIR/platforms/unix/vm/sqUnixMain.c"
fi

if [ "$SQUEAK_VM_FLAVOR" = "v3" ]; then
    echo "==> Preparing V3 6502 interpreter source..."
    mkdir -p "$SRC_DIR/$VM_SRC_DIR"
    git show "$SQUEAK_V3_6502_COMMIT:src/vm/interp.c" > "$SRC_DIR/$VM_SRC_DIR/interp.c"
    cp "$SRC_DIR/$VM_SRC_DIR/interp.c" "$SRC_DIR/$VM_SRC_DIR/gcc3x-interp.c"
    git show "$SQUEAK_V3_6502_COMMIT:src/vm/interp.h" > "$SRC_DIR/$VM_SRC_DIR/interp-6502.h"
    cp "$SRC_DIR/src/v3.stack/interp.h" "$SRC_DIR/$VM_SRC_DIR/interp.h"
    cp "$SRC_DIR/src/v3.stack/vmCallback.h" "$SRC_DIR/$VM_SRC_DIR/vmCallback.h"
    perl -0pi -e '
        s/#include <setjmp\.h>/#include <setjmp.h>\n#include <string.h>/;
        s/#include "sqMemoryAccess\.h"/#include "sqMemoryAccess.h"\n#include "sqImageFileAccess.h"\n#include "interp-6502.h"\n#define clone sqOldClone/;
        s/#define clone sqOldClone/#define clone sqOldClone\n\nstatic sqInt attributeSize(sqInt id) {\n    const char *attribute = getAttributeString(id);\n    return attribute ? strlen(attribute) : 0;\n}\n\nstatic sqInt getAttributeIntoLength(sqInt id, sqInt byteArrayIndex, sqInt length) {\n    const char *attribute = getAttributeString(id);\n    if (attribute && length > 0) {\n        memcpy(pointerForOop(byteArrayIndex), attribute, length);\n    }\n    return 0;\n}\n\nsqInt ioGetButtonState(void);\nsqInt ioGetKeystroke(void);\nsqInt ioMousePoint(void);\nsqInt ioPeekKeystroke(void);/;
        s/\(void \*\)(clearProfile|dumpProfile|startProfiling|stopProfiling)/(void *)primitiveFail/g;
        s/\bsqInt readImageFromFileHeapSizeStartingAt\(sqImageFile/size_t readImageFromFileHeapSizeStartingAt(sqImageFile/g;
        s/sqGetFilenameFromString\(aCharBuffer, aFilenameString, filenameLength, aBoolean\);\n\}/return sqGetFilenameFromString(aCharBuffer, aFilenameString, filenameLength, aBoolean);\n}/g;
        s/\bsqInt popthenPush\(sqInt nItems, sqInt oop\);/void popthenPush(sqInt nItems, sqInt oop);/g;
        s/\bsqInt pushRemappableOop\(sqInt oop\);/void pushRemappableOop(sqInt oop);/g;
        s/\bsqInt popthenPush\(sqInt nItems, sqInt oop\) \{/void popthenPush(sqInt nItems, sqInt oop) {/g;
        s/\bsqInt pushRemappableOop\(sqInt oop\) \{/void pushRemappableOop(sqInt oop) {/g;
        s/void \(\*primitiveFunctionPointer\)\(\);/sqInt (*primitiveFunctionPointer)(void);/g;
        s/sqInt dispatchFunctionPointer\(void \*aFunctionPointer\) \{\n\t\(\(void \(\*\)\(void\)\)aFunctionPointer\)\(\);\n\}/sqInt dispatchFunctionPointer(void *aFunctionPointer) {\n    return ((sqInt (*)(void))aFunctionPointer)();\n}/g;
        s/sqInt dummyReferToProxy\(void\) \{\n\tinterpreterProxy = interpreterProxy;\n\}/sqInt dummyReferToProxy(void) {\n\tinterpreterProxy = interpreterProxy;\n}\n\nsqInt stringForCString(char *aCString) {\nregister struct foo * foo = \&fum;\n    sqInt result;\n    sqInt size;\n\n    if (aCString == null) {\n        return null;\n    }\n    size = strlen(aCString);\n    result = instantiateClassindexableSize(fetchPointerofObject(ClassString, foo->specialObjectsOop), size);\n    if (result != null) {\n        memcpy(pointerForOop(result + BASE_HEADER_SIZE), aCString, size);\n    }\n    return result;\n}\n\nsqInt methodReturnValue(sqInt oop) {\nregister struct foo * foo = \&fum;\n    if (failed()) {\n        return 0;\n    }\n    popthenPush(foo->argumentCount + 1, oop);\n    return 0;\n}\n\nsqInt methodReturnBool(sqInt boolean) {\nregister struct foo * foo = \&fum;\n    return methodReturnValue(boolean ? foo->trueObj : foo->falseObj);\n}\n\nsqInt methodReturnFloat(double aFloat) {\n    return methodReturnValue(floatObjectOf(aFloat));\n}\n\nsqInt methodReturnInteger(sqInt integer) {\n    return methodReturnValue(integerObjectOf(integer));\n}\n\nsqInt methodReturnReceiver(void) {\nregister struct foo * foo = \&fum;\n    if (failed()) {\n        return 0;\n    }\n    pop(foo->argumentCount);\n    return 0;\n}\n\nsqInt methodReturnString(char *aCString) {\n    sqInt result;\n\n    result = stringForCString(aCString);\n    if (result == null) {\n        return primitiveFail();\n    }\n    return methodReturnValue(result);\n}\n\nsqInt topRemappableOop(void) {\nregister struct foo * foo = \&fum;\n    return foo->remapBuffer[foo->remapBufferCount];\n}/g;
        s/sqInt topRemappableOop\(void\) \{\nregister struct foo \* foo = \&fum;\n    return foo->remapBuffer\[foo->remapBufferCount\];\n\}/sqInt topRemappableOop(void) {\nregister struct foo * foo = \&fum;\n    return foo->remapBuffer[foo->remapBufferCount];\n}\n\nsqInt statNumGCs(void) {\nregister struct foo * foo = \&fum;\n    return foo->statIncrGCs + foo->statFullGCs;\n}/g;
        s/sqInt statNumGCs\(void\) \{\nregister struct foo \* foo = \&fum;\n    return foo->statIncrGCs \+ foo->statFullGCs;\n\}/sqInt statNumGCs(void) {\nregister struct foo * foo = \&fum;\n    return foo->statIncrGCs + foo->statFullGCs;\n}\n\nsqInt characterObjectOf(sqInt characterValue) {\n    return characterForAscii(characterValue);\n}\n\nsqInt characterValueOf(sqInt characterObject) {\n    return fetchIntegerofObject(CharacterValueIndex, characterObject);\n}\n\nsqInt fileTimesInUTC(void) {\n    return 1;\n}\n\nsqInt isBooleanObject(sqInt oop) {\nregister struct foo * foo = \&fum;\n    return (oop == foo->trueObj) || (oop == foo->falseObj);\n}\n\nsqInt isImmediate(sqInt anOop) {\n    return anOop \& 1;\n}\n\nsqInt isCharacterObject(sqInt oop) {\n    return ((oop \& 1) == 0) \&\& (fetchClassOf(oop) == classCharacter());\n}\n\nsqInt isCharacterValue(sqInt anInteger) {\n    return (anInteger >= 0) \&\& (anInteger <= 0xFF);\n}\n\nsqInt isOopImmutable(sqInt anOop) {\n    return anOop \& 1;\n}\n\nsqInt isOopMutable(sqInt anOop) {\n    return (anOop \& 1) == 0;\n}\n\nsqInt bytesPerElement(sqInt oop) {\n    sqInt format;\n\n    if (oop \& 1) {\n        return 0;\n    }\n    format = (((usqInt)longAt(oop)) >> 8) \& 15;\n    if (format == 6) {\n        return BYTES_PER_WORD;\n    }\n    if (format >= 8) {\n        return 1;\n    }\n    return BYTES_PER_WORD;\n}\n\nsqInt isShorts(sqInt oop) {\n    return 0;\n}\n\nsqInt isWordsOrShorts(sqInt oop) {\n    return ((oop \& 1) == 0) \&\& (((((usqInt)longAt(oop)) >> 8) \& 15) == 6);\n}\n\nsqInt isLong64s(sqInt oop) {\n    return 0;\n}\n\nsqInt isYoung(sqInt oop) {\n    return 0;\n}\n\nsqInt classWordArray(void) {\nregister struct foo * foo = \&fum;\n    return fetchPointerofObject(ClassBitmap, foo->specialObjectsOop);\n}\n\nsqInt classDoubleByteArray(void) {\nregister struct foo * foo = \&fum;\n    return foo->nilObj;\n}\n\nsqInt classDoubleWordArray(void) {\nregister struct foo * foo = \&fum;\n    return foo->nilObj;\n}\n\nsqInt classFloat32Array(void) {\nregister struct foo * foo = \&fum;\n    return foo->nilObj;\n}\n\nsqInt classFloat64Array(void) {\nregister struct foo * foo = \&fum;\n    return foo->nilObj;\n}\n\nsqInt primitiveFailForOSError(sqLong osErrorCode) {\n    return primitiveFailFor(PrimErrOSError);\n}\n\nsqInt primitiveFailForwithSecondary(sqInt reasonCode, sqLong extraErrorCode) {\n    return primitiveFailFor(reasonCode);\n}\n\nsqInt primitiveFailForFFIExceptionat(usqLong exceptionCode, usqInt pc) {\n    return primitiveFailFor(PrimErrUnsupported);\n}\n\nsqInt primitiveFailureCode(void) {\nregister struct foo * foo = \&fum;\n    return foo->primFailCode;\n}\n\nvoid forceInterruptCheckFromHeartbeat(void) {\n    forceInterruptCheck();\n}\n\nvoid addIdleUsecs(sqInt idleUsecs) {\n}\n\nvoid warning(const char *message) {\n}/g;
        s/void warning\(const char \*message\) \{\n\}/void warning(const char *message) {\n}\n\nsqInt cloneObject(sqInt objOop) {\n    return clone(objOop);\n}\n\nusqInt storeLong32ofObjectwithValue(sqInt index, sqInt oop, usqInt value) {\n    long32Atput((oop + BASE_HEADER_SIZE) + (index << 2), value);\n    return value;\n}\n\nvoid *setInterruptCheckChain(void (*aFunction)(void)) {\n    return 0;\n}\n\nsqInt unpinObject(sqInt objOop) {\n    return objOop;\n}\n\nsqInt pinObject(sqInt objOop) {\n    return objOop;\n}\n\nsqInt isPinned(sqInt objOop) {\n    return 0;\n}\n\nsqInt signalNoResume(sqInt aSemaphore) {\n    return primitiveFail();\n}\n\nsqInt sizeOfAlienData(sqInt objOop) {\n    return lengthOf(objOop);\n}\n\nvoid *startOfAlienData(sqInt objOop) {\n    return pointerForOop(objOop + BASE_HEADER_SIZE);\n}\n\nchar *cStringOrNullFor(sqInt oop) {\nregister struct foo * foo = \&fum;\n    if (oop == foo->nilObj) {\n        return 0;\n    }\n    return pointerForOop(oop + BASE_HEADER_SIZE);\n}\n\nusqIntptr_t positiveMachineIntegerValueOf(sqInt oop) {\n    return positive32BitValueOf(oop);\n}\n\nusqIntptr_t stackPositiveMachineIntegerValue(sqInt offset) {\n    return positiveMachineIntegerValueOf(stackValue(offset));\n}\n\nsqIntptr_t signedMachineIntegerValueOf(sqInt oop) {\n    return signed32BitValueOf(oop);\n}\n\nsqIntptr_t stackSignedMachineIntegerValue(sqInt offset) {\n    return signedMachineIntegerValueOf(stackValue(offset));\n}\n\nsqInt sendInvokeCallbackContext(vmccp callbackContext) {\n    return primitiveFail();\n}\n\nsqInt returnAsThroughCallbackContext(sqInt result, vmccp callbackContext, sqInt flags) {\n    return primitiveFail();\n}\n\nsqInt instanceSizeOf(sqInt aClass) {\n    return 0;\n}\n\nsqInt primitiveErrorTable(void) {\nregister struct foo * foo = \&fum;\n    return foo->nilObj;\n}\n\nsqInt isKindOfClass(sqInt oop, sqInt aClass) {\n    return ((oop \& 1) == 0) \&\& (fetchClassOf(oop) == aClass);\n}\n\nsqInt tenuringIncrementalGC(void) {\n    return 0;\n}\n\nsqInt ownVM(sqInt threadIndexAndFlags) {\n    return threadIndexAndFlags;\n}\n\nsqInt disownVM(sqInt flags) {\n    return flags;\n}\n\nsqInt identityHashOf(sqInt oop) {\n    if (oop \& 1) {\n        return oop >> 1;\n    }\n    return (((usqInt)longAt(oop)) >> 17) \& 4095;\n}\n\nsqInt isPositiveMachineIntegerObject(sqInt oop) {\n    return (oop \& 1) \&\& (oop >= 1);\n}\n\nvoid setBreakSelector(char *selector) {\n}\n\nvoid setBreakMNUSelector(char *selector) {\n}/g;
        s/sqInt printCallStack\(void\);/void printCallStack(void);/g;
        s/EXPORT\(sqInt\) printAllStacks\(void\);/EXPORT(void) printAllStacks(void);/g;
        s/EXPORT\(sqInt\) printAllStacks\(void\) \{/EXPORT(void) printAllStacks(void) {/g;
        s/sqInt printCallStack\(void\) \{\n\treturn printCallStackOf\(foo->activeContext\);\n\}/void printCallStack(void) {\n\tprintCallStackOf(foo->activeContext);\n}\n\nvoid printAllStacksOn(FILE *file) {\n\tprintAllStacks();\n}\n\nvoid printCallStackOn(FILE *file) {\n\tprintCallStack();\n}\n\nvoid dumpPrimTraceLogOn(FILE *file) {\n}\n\nvoid dumpPrimTraceLog(void) {\n}/;
    ' "$SRC_DIR/$VM_SRC_DIR/interp.c" "$SRC_DIR/$VM_SRC_DIR/gcc3x-interp.c"
    if ! grep -q KANDELO_V3_INPUT_COMPAT "$SRC_DIR/platforms/unix/vm-display-fbdev/sqUnixFBDev.c"; then
        perl -0pi -e '
            s/#include "sqUnixEvent\.c"/#include "sqUnixEvent.c"\n\n#ifndef KANDELO_V3_INPUT_COMPAT\n#define KANDELO_V3_INPUT_COMPAT 1\nsqInt ioGetButtonState(void) { return display_ioGetButtonState(); }\nsqInt ioGetKeystroke(void) { return display_ioGetKeystroke(); }\nsqInt ioMousePoint(void) { return display_ioMousePoint(); }\nsqInt ioPeekKeystroke(void) { return display_ioPeekKeystroke(); }\n#endif/;
        ' "$SRC_DIR/platforms/unix/vm-display-fbdev/sqUnixFBDev.c"
    fi
    if ! grep -q KANDELO_V3_FLEXIBLE_DISPLAY "$SRC_DIR/platforms/unix/vm-display-fbdev/sqUnixFBDev.c"; then
        perl -0pi -e '
            s/static sqInt display_ioShowDisplay\(sqInt dispBitsIndex, sqInt width, sqInt height, sqInt depth, sqInt affectedL, sqInt affectedR, sqInt affectedT, sqInt affectedB\)\n\{\n  if \(\(depth  != fb_depth\(fb\)\) \|\| \(width  != fb_width\(fb\)\) \|\| \(height != fb_height\(fb\)\)\n      \|\| \(affectedR < affectedL\) \|\| \(affectedB < affectedT\)\)\n    return 0;\n  fb->copyBits\(fb, pointerForOop\(dispBitsIndex\), affectedL, affectedR, affectedT, affectedB\);\n  return 1;\n\}/#ifndef KANDELO_V3_FLEXIBLE_DISPLAY\n#define KANDELO_V3_FLEXIBLE_DISPLAY 1\nstatic void kandelo_copyBits32FromWidth(struct fb *target, char *bits, int sourceWidth, int left, int right, int top, int bottom)\n{\n  int x, y;\n  hideCursorIn(target, left, right, top, bottom);\n  for (y = top; y < bottom; y += 1) {\n    pixel_t *in = (pixel_t *)(bits + ((left + (y * sourceWidth)) * 4));\n    pixel_t *out = (pixel_t *)(target->addr + fb_pixel_position(target, left, y));\n    for (x = left; x < right; x += 1, in += 1, out += 1) {\n      out[0] = in[0];\n    }\n  }\n  showCursorIn(target, left, right, top, bottom);\n}\n#endif\n\nstatic sqInt display_ioShowDisplay(sqInt dispBitsIndex, sqInt width, sqInt height, sqInt depth, sqInt affectedL, sqInt affectedR, sqInt affectedT, sqInt affectedB)\n{\n  if ((depth != fb_depth(fb)) || (affectedR < affectedL) || (affectedB < affectedT))\n    return 0;\n  affectedL = max(0, affectedL);\n  affectedT = max(0, affectedT);\n  affectedR = min(width, affectedR);\n  affectedB = min(height, affectedB);\n  if ((affectedR <= affectedL) || (affectedB <= affectedT))\n    return 1;\n  if ((width == fb_width(fb)) && (height == fb_height(fb))) {\n    fb->copyBits(fb, pointerForOop(dispBitsIndex), affectedL, affectedR, affectedT, affectedB);\n    return 1;\n  }\n  if ((depth == 32) && (width <= fb_width(fb)) && (height <= fb_height(fb))) {\n    kandelo_copyBits32FromWidth(fb, pointerForOop(dispBitsIndex), width, affectedL, affectedR, affectedT, affectedB);\n    return 1;\n  }\n  return 0;\n}/;
            s/return width == fb_width\(fb\) && height == fb_height\(fb\) && depth == fb_depth\(fb\);/return width <= fb_width(fb) \&\& height <= fb_height(fb) \&\& depth == fb_depth(fb);/;
        ' "$SRC_DIR/platforms/unix/vm-display-fbdev/sqUnixFBDev.c"
    fi
    if ! grep -q KANDELO_V3_HEARTBEAT_ON_CLOCK "$SRC_DIR/platforms/unix/vm/sqUnixHeartbeat.c"; then
        perl -0pi -e '
            s/#if defined\(__wasm32__\)\n\tupdateMicrosecondClock\(\);\n#endif\n\treturn millisecondClock;/#if defined(__wasm32__)\n# define KANDELO_V3_HEARTBEAT_ON_CLOCK 1\n\tupdateMicrosecondClock();\n\tforceInterruptCheckFromHeartbeat();\n#endif\n\treturn millisecondClock;/;
        ' "$SRC_DIR/platforms/unix/vm/sqUnixHeartbeat.c"
    fi
    for plugin_source in \
        "$SRC_DIR/src/plugins/FilePlugin/FilePlugin.c" \
        "$SRC_DIR/src/plugins/LargeIntegers/LargeIntegers.c" \
        "$SRC_DIR/src/plugins/MiscPrimitivePlugin/MiscPrimitivePlugin.c" \
        "$SRC_DIR/src/plugins/B2DPlugin/B2DPlugin.c" \
        "$SRC_DIR/src/plugins/BitBltPlugin/BitBltPlugin.c" \
        "$SRC_DIR/src/plugins/ZipPlugin/ZipPlugin.c" \
        "$SRC_DIR/src/plugins/SecurityPlugin/SecurityPlugin.c" \
        "$SRC_DIR/src/plugins/SocketPlugin/SocketPlugin.c" \
        "$SRC_DIR/src/plugins/SqueakSSL/SqueakSSL.c"; do
        perl -0pi -e '
            s/#if defined\(__wasm32__\)\n# define DEFINE_PLUGIN_PRIMITIVE_VOID_WRAPPER/#if defined(__wasm32__) \&\& !defined(KANDELO_V3_PRIMITIVE_ABI)\n# define DEFINE_PLUGIN_PRIMITIVE_VOID_WRAPPER/g;
            s/\bextern sqInt popthenPush\(sqInt nItems, sqInt oop\);/extern void popthenPush(sqInt nItems, sqInt oop);/g;
            s/\bextern sqInt pushRemappableOop\(sqInt oop\);/extern void pushRemappableOop(sqInt oop);/g;
        ' "$plugin_source"
    done
    perl -0pi -e '
        s/EXPORT\(void\) primitiveUpdateGZipCrc32\(void\);/EXPORT(sqInt) primitiveUpdateGZipCrc32(void);/g;
        s/EXPORT\(void\)\nprimitiveUpdateGZipCrc32\(void\)/EXPORT(sqInt)\nprimitiveUpdateGZipCrc32(void)/g;
        s/if \(failed\(\)\) \{\n\t\treturn;\n\t\}/if (failed()) {\n\t\treturn 0;\n\t}/g;
        s/primitiveFail\(\);\n\t\treturn;/primitiveFail();\n\t\treturn 0;/g;
        s/methodReturnValue\(positive32BitIntegerFor\(crc\)\);\n\}/methodReturnValue(positive32BitIntegerFor(crc));\n\treturn 0;\n}/g;
    ' "$SRC_DIR/src/plugins/ZipPlugin/ZipPlugin.c"
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$BIN_DIR"

echo "INTERNAL_PLUGINS = FilePlugin LargeIntegers MiscPrimitivePlugin B2DPlugin BitBltPlugin ZipPlugin SecurityPlugin SocketPlugin SqueakSSL" > "$BUILD_DIR/plugins.int"
: > "$BUILD_DIR/plugins.ext"

cd "$BUILD_DIR"

echo "==> Configuring $VM_LABEL for wasm32-posix..."
"$SRC_DIR/platforms/unix/config/configure" \
    --host=wasm32-unknown-none \
    --prefix=/usr \
    --disable-shared \
    --enable-static \
    --with-vmversion=5.0 \
    --with-src="$VM_SRC_DIR" \
    --disable-cogit \
    --without-npsqueak \
    --without-x \
    --without-gl \
    --without-zlib \
    --disable-iconv \
    --disable-epoll \
    --with-scriptname=squeak \
    CC=wasm32posix-cc \
    AR=wasm32posix-ar \
    RANLIB=wasm32posix-ranlib \
    NM=wasm32posix-nm \
    STRIP=wasm32posix-strip \
    CPPFLAGS="-I$OPENSSL_DIR/include" \
    ac_cv_header_libevdev_1_0_libevdev_libevdev_h=yes \
    ac_cv_sizeof_int=4 \
    ac_cv_sizeof_long=4 \
    ac_cv_sizeof_long_long=8 \
    ac_cv_sizeof_void_p=4 \
    CFLAGS="-O2 -fno-strict-aliasing -fwrapv -DNDEBUG -DDEBUGVM=0 -DMUSL -DNOEVDEV -DSTACK_FP_ALIGNMENT=0 -DLSB_FIRST=1 -DHAVE_CONFIG_H -Wno-incompatible-function-pointer-types $SQUEAK_EXTRA_CFLAGS -I$REPO_ROOT/sysroot/include -I$OPENSSL_DIR/include" \
    LIBS="-lm"

echo "==> Compiling static display and sound modules..."
MODULE_CFLAGS=(
    -O2 -fno-strict-aliasing -fwrapv -DNDEBUG -DDEBUGVM=0 -DMUSL -DNOEVDEV -DSTACK_FP_ALIGNMENT=0 -DHAVE_CONFIG_H -DLSB_FIRST=1
    -Wno-incompatible-function-pointer-types
    $SQUEAK_EXTRA_CFLAGS
    -I"$BUILD_DIR"
    -I"$REPO_ROOT/sysroot/include"
    -I"$SRC_DIR/platforms/unix/vm"
    -I"$SRC_DIR/platforms/Cross/vm"
    -I"$SRC_DIR/$VM_SRC_DIR"
    -I"$SRC_DIR/platforms/unix/vm-display-fbdev"
    -I"$SRC_DIR/platforms/Cross/plugins/FilePlugin"
    -I"$SRC_DIR/platforms/unix/plugins/FilePlugin"
    -I"$SRC_DIR/src/plugins/FilePlugin"
    -I"$SRC_DIR/src/plugins/LargeIntegers"
    -I"$SRC_DIR/src/plugins/MiscPrimitivePlugin"
    -I"$SRC_DIR/src/plugins/B2DPlugin"
    -I"$SRC_DIR/src/plugins/BitBltPlugin"
    -I"$SRC_DIR/src/plugins/ZipPlugin"
    -I"$SRC_DIR/platforms/Cross/plugins/BitBltPlugin"
    -I"$SRC_DIR/platforms/Cross/plugins/B3DAcceleratorPlugin"
    -I"$SRC_DIR/platforms/unix/plugins/B3DAcceleratorPlugin"
    -I"$SRC_DIR/src/plugins/SecurityPlugin"
    -I"$SRC_DIR/platforms/Cross/plugins/SecurityPlugin"
    -I"$SRC_DIR/platforms/unix/plugins/SecurityPlugin"
    -I"$SRC_DIR/src/plugins/SocketPlugin"
    -I"$SRC_DIR/platforms/Cross/plugins/SocketPlugin"
    -I"$SRC_DIR/platforms/unix/plugins/SocketPlugin"
    -I"$SRC_DIR/src/plugins/SqueakSSL"
    -I"$SRC_DIR/platforms/Cross/plugins/SqueakSSL"
    -I"$SRC_DIR/platforms/unix/plugins/SqueakSSL"
    -I"$OPENSSL_DIR/include"
)
wasm32posix-cc "${MODULE_CFLAGS[@]}" \
    -c "$SRC_DIR/platforms/unix/vm-display-fbdev/sqUnixFBDev.c" \
    -o sqUnixFBDev.o
wasm32posix-cc "${MODULE_CFLAGS[@]}" \
    -c "$SRC_DIR/platforms/unix/vm-sound-OSS/sqUnixSoundOSS.c" \
    -o sqUnixSoundOSS.o

echo "==> Building VM support objects..."
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
VM_SUPPORT_OBJECTS=(
    sqNamedPrims.o
    sqVirtualMachine.o
    sqHeapMap.o
    sqTicker.o
    aio.o
    debug.o
    osExports.o
    sqUnixExternalPrims.o
    sqUnixMemory.o
)
if [ "$SQUEAK_VM_FLAVOR" != "v3" ]; then
    VM_SUPPORT_OBJECTS+=("sqExternalSemaphores.o")
fi
if [ -n "$VM_EXTRA_MEMORY_OBJECT" ]; then
    VM_SUPPORT_OBJECTS+=("$VM_EXTRA_MEMORY_OBJECT")
fi
VM_SUPPORT_OBJECTS+=(
    sqUnixCharConv.o
    sqUnixMain.o
    sqUnixVMProfile.o
    sqUnixHeartbeat.o
    sqUnixThreads.o
    sqUnixDisplayHelpers.o
)
make -C vm -j"$JOBS" AR=wasm32posix-ar "${VM_SUPPORT_OBJECTS[@]}"
"$SRC_DIR/platforms/unix/config/verstamp" version.c wasm32posix-cc
wasm32posix-cc "${MODULE_CFLAGS[@]}" -c version.c -o version.o
wasm32posix-cc "${MODULE_CFLAGS[@]}" -c disabledPlugins.c -o disabledPlugins.o

echo "==> Compiling internal plugins..."
PLUGIN_CFLAGS=(
    "${MODULE_CFLAGS[@]}"
    -DSQUEAK_BUILTIN_PLUGIN
    -DSQSSL_OPENSSL_LINKED
    -Wno-unused-function
    -Wno-unused-variable
    -Wno-unused-but-set-variable
)
if [ "$SQUEAK_VM_FLAVOR" = "v3" ]; then
    PLUGIN_CFLAGS+=(-DKANDELO_V3_PRIMITIVE_ABI)
fi
wasm32posix-cc "${PLUGIN_CFLAGS[@]}" \
    -c "$SRC_DIR/src/plugins/FilePlugin/FilePlugin.c" \
    -o FilePlugin.o
wasm32posix-cc "${PLUGIN_CFLAGS[@]}" \
    -c "$SRC_DIR/platforms/unix/plugins/FilePlugin/sqUnixFile.c" \
    -o sqUnixFile.o
wasm32posix-cc "${PLUGIN_CFLAGS[@]}" \
    -c "$SRC_DIR/platforms/Cross/plugins/FilePlugin/sqFilePluginBasicPrims.c" \
    -o sqFilePluginBasicPrims.o
wasm32posix-cc "${PLUGIN_CFLAGS[@]}" \
    -c "$SRC_DIR/src/plugins/LargeIntegers/LargeIntegers.c" \
    -o LargeIntegers.o
wasm32posix-cc "${PLUGIN_CFLAGS[@]}" \
    -c "$SRC_DIR/src/plugins/MiscPrimitivePlugin/MiscPrimitivePlugin.c" \
    -o MiscPrimitivePlugin.o
wasm32posix-cc "${PLUGIN_CFLAGS[@]}" \
    -c "$SRC_DIR/src/plugins/B2DPlugin/B2DPlugin.c" \
    -o B2DPlugin.o
wasm32posix-cc "${PLUGIN_CFLAGS[@]}" \
    -c "$SRC_DIR/src/plugins/BitBltPlugin/BitBltPlugin.c" \
    -o BitBltPlugin.o
wasm32posix-cc "${PLUGIN_CFLAGS[@]}" \
    -c "$SRC_DIR/platforms/Cross/plugins/BitBltPlugin/BitBltDispatch.c" \
    -o BitBltDispatch.o
wasm32posix-cc "${PLUGIN_CFLAGS[@]}" \
    -c "$SRC_DIR/platforms/Cross/plugins/BitBltPlugin/BitBltGeneric.c" \
    -o BitBltGeneric.o
wasm32posix-cc "${PLUGIN_CFLAGS[@]}" \
    -c "$SRC_DIR/src/plugins/ZipPlugin/ZipPlugin.c" \
    -o ZipPlugin.o
wasm32posix-cc "${PLUGIN_CFLAGS[@]}" \
    -c "$SRC_DIR/src/plugins/SecurityPlugin/SecurityPlugin.c" \
    -o SecurityPlugin.o
wasm32posix-cc "${PLUGIN_CFLAGS[@]}" \
    -c "$SRC_DIR/platforms/unix/plugins/SecurityPlugin/sqUnixSecurity.c" \
    -o sqUnixSecurity.o
wasm32posix-cc "${PLUGIN_CFLAGS[@]}" \
    -c "$SRC_DIR/src/plugins/SocketPlugin/SocketPlugin.c" \
    -o SocketPlugin.o
wasm32posix-cc "${PLUGIN_CFLAGS[@]}" \
    -c "$SRC_DIR/platforms/unix/plugins/SocketPlugin/sqUnixSocket.c" \
    -o sqUnixSocket.o
wasm32posix-cc "${PLUGIN_CFLAGS[@]}" \
    -c "$SRC_DIR/src/plugins/SqueakSSL/SqueakSSL.c" \
    -o SqueakSSL.o
wasm32posix-cc "${PLUGIN_CFLAGS[@]}" \
    -c "$SRC_DIR/platforms/unix/plugins/SqueakSSL/sqUnixSSL.c" \
    -o sqUnixSSL.o

echo "==> Compiling stack interpreter..."
wasm32posix-cc "${MODULE_CFLAGS[@]}" \
    -Wno-unused-value \
    -Wno-pointer-sign \
    -Wno-incompatible-pointer-types-discards-qualifiers \
    -Wno-format \
    -I"$SRC_DIR/platforms/unix/plugins/FilePlugin" \
    -c "$SRC_DIR/$VM_SRC_DIR/interp.c" \
    -o vm/interp.o

CORE_OBJECTS=(
    disabledPlugins.o
    version.o
)
for obj in "${VM_SUPPORT_OBJECTS[@]}"; do
    CORE_OBJECTS+=("vm/$obj")
done
PLUGIN_OBJECTS=(
    FilePlugin.o
    sqUnixFile.o
    sqFilePluginBasicPrims.o
    LargeIntegers.o
    MiscPrimitivePlugin.o
    B2DPlugin.o
    BitBltPlugin.o
    BitBltDispatch.o
    BitBltGeneric.o
    ZipPlugin.o
    SecurityPlugin.o
    sqUnixSecurity.o
    SocketPlugin.o
    sqUnixSocket.o
    SqueakSSL.o
    sqUnixSSL.o
)

cat > main-adapter.c <<'EOF'
extern char **environ;
extern int main(int argc, char **argv, char **envp);
extern int sqPreInitializeSSL(void);
int __main_argc_argv(int argc, char **argv) {
    (void)sqPreInitializeSSL();
    return main(argc, argv, environ);
}
EOF
if [ "$SQUEAK_VM_FLAVOR" = "v3" ]; then
    cat >> main-adapter.c <<'EOF'
int ioGetMaxExtSemTableSize(void) { return 0; }
void ioSetMaxExtSemTableSize(int n) { (void)n; }
void ioInitExternalSemaphores(void) {}
EOF
fi
wasm32posix-cc "${MODULE_CFLAGS[@]}" -c main-adapter.c -o main-adapter.o

echo "==> Linking Squeak VM..."
wasm32posix-cc \
    -O2 -fno-strict-aliasing -fwrapv -DNDEBUG -DDEBUGVM=0 -DMUSL -DNOEVDEV -DSTACK_FP_ALIGNMENT=0 \
    -Wno-incompatible-function-pointer-types \
    -o "$VM_EXECUTABLE" \
    main-adapter.o \
    sqUnixFBDev.o \
    sqUnixSoundOSS.o \
    vm/interp.o \
    "${CORE_OBJECTS[@]}" \
    "${PLUGIN_OBJECTS[@]}" \
    "$OPENSSL_DIR/lib/libssl.a" \
    "$OPENSSL_DIR/lib/libcrypto.a" \
    -lm \
    -pthread

if [ "$(wc -c < "$VM_EXECUTABLE" | tr -d ' ')" -lt 100000 ]; then
    echo "ERROR: squeak output is unexpectedly small" >&2
    exit 1
fi

cp "$VM_EXECUTABLE" "$BIN_DIR/$SQUEAK_OUTPUT_NAME"
cd "$REPO_ROOT"
source "$REPO_ROOT/scripts/install-local-binary.sh"
install_local_binary "$SQUEAK_PACKAGE_NAME" "$BIN_DIR/$SQUEAK_OUTPUT_NAME"

ls -lh "$BIN_DIR/$SQUEAK_OUTPUT_NAME"
echo "==> $VM_LABEL built."

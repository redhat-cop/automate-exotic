#!/bin/sh -x
#
# This script builds & bundles Python for Android
# You'll end up with a tar.bz2 file that contains a Python distribution
#
# Requires all prerequisites to build Android on the host, and the NDK
# installed.
#
# This script creates a file python4android.tgz. Unpack it on your device
# (into a non-noexec partition!) and enjoy.
#
set -e

# Set the correct NDK path here!
NDK=~/Public/Android/SdK/ndk-bundle
# Enter the correct Python version
PYVER=2.7
PYMINVER=${PYVER}.15

# This shouldn't need to be updated often.. but it might need updating, so check this:
# arm64
ANDRO_HOST=aarch64-linux-android
ANDRO_PROC=arm64
# arm
#ANDRO_HOST=arm-linux-androideabi
#ANDRO_PROC=arm
ANDRO_API=24

NDK_TOOLCHAIN=$NDK/toolchains/${ANDRO_HOST}-4.9/prebuilt/linux-x86_64/bin
NDK_PLATFORM=$NDK/platforms/android-${ANDRO_API}/arch-${ANDRO_PROC}
NDK_SYSROOT=$NDK/sysroot

## The remainder shouldn't need any changes, unless you want a newer Python version:

MYBUILDDIR=${PWD}
MYFILESDIR=$(readlink -f $(dirname $0))

# 0) Put together an Android sysroot from the NDK

rm -fr sysroot
cp -r ${NDK_PLATFORM} sysroot
cp -r ${NDK_SYSROOT}/usr/include sysroot/usr/include
mv sysroot/usr/include/${ANDRO_HOST}/asm sysroot/usr/include/
if [[ ${ANDRO_API} -lt 26 ]]
then # avoid nl_langinfo error messages
	rm sysroot/usr/include/langinfo.h
fi

# 1) Download Python
wget -N https://www.python.org/ftp/python/${PYMINVER}/Python-${PYMINVER}.tar.xz
rm -fr Python-${PYMINVER}
rm -fr prefix
tar xaf Python-${PYMINVER}.tar.xz
cd Python-${PYMINVER}

# 2) Compile host pgen/python
(
	./configure
	make python Parser/pgen
	mv python pythonh
	mv Parser/pgen Parser/pgenh
) 2>&1 | tee host-build.log

# 3) Patch the Makefile to use the host versions
sed -i -re 's#^(\s+)\$\(PGEN\)#\1$(PGEN)h#m' Makefile.pre.in
sed -i -re 's#./\$\(BUILDPYTHON\)#./$(BUILDPYTHON)h#m' Makefile.pre.in

make distclean

# 4) Patch some usually misdetected functions, setup modules to compile and fix some other problems
sed -i -re 's# ftime # #' configure
sed -i -re 's#p->pw_gecos#""#' Modules/pwdmodule.c
sed -i -re "s#exit_status = .+#exit_status = 0#" Lib/compileall.py
sed -i -re "s#ret = os.system\\('%s -E -v - </dev/null 2>%s 1>/dev/null' % \\(gcc, tmpfile\\)\\)#ret = os.system('%s %s -E -v - </dev/null 2>%s 1>/dev/null' % (gcc, sysconfig.get_config_var('CPPFLAGS'), tmpfile))#" setup.py

for MOD in _socket array cmath math _struct time operator _random _collections _heapq itertools strop _functools _elementtree datetime _bisect unicodedata _locale fcntl "select" mmap _md5 _sha256 _sha512 _sha binascii cPickle cStringIO _io zlib; do
	grep "#$MOD" Modules/Setup.dist | grep "\.c" | sed -re 's%^#%%' >> Modules/Setup.local
done

# 5) Configure
export PATH=${PATH}:${NDK_TOOLCHAIN}
export SYSROOT=${MYBUILDDIR}/sysroot
export CFLAGS="-fPIC -fPIE --sysroot $SYSROOT -Dandroid -mandroid"
export CPP="${ANDRO_HOST}-cpp"
export CPPFLAGS="--sysroot $SYSROOT"
export LDFLAGS="--sysroot $SYSROOT"
export ac_cv_file__dev_ptmx=no
export ac_cv_file__dev_ptc=no
./configure --disable-ipv6 --host=${ANDRO_HOST} --build=x86_64-linux-gnu ac_cv_file__dev_ptmx=no ac_cv_file__dev_ptc=no 2>&1 | tee dev-build.log

# 6) Fix some mistakes configure made
sed -i -re "s%^#define HAVE_GETHOSTBYNAME_.+%%" pyconfig.h
echo "#define HAVE_GETHOSTBYNAME 1" >> pyconfig.h

# 7) Compile python
make 2>&1 | tee -a dev-build.log

# 8) Recompile the python executable as a position independent executable
rm -f python
sed -i -re 's#^LDFLAGS=#LDFLAGS= -pie #' Makefile
make 2>&1 | tee deb-build-pie.log

# 9) Install into our prefix and prepare an archive
make install DESTDIR=${MYBUILDDIR}/prefix 2>&1 | tee install.log
cd ${MYBUILDDIR}/prefix/usr/local/lib
rm -f *.a
cd python*
rm -rf test
find -iname "*.pyc" -exec rm \{\} \;
cd ../../bin
${ANDRO_HOST}-strip python${PYVER}

cd ..

# 10) Create a grp.py for Android based on OS/2 source
cp ${MYBUILDDIR}/Python-${PYMINVER}/Lib/plat-os2emx/grp.py lib/python${PYVER}/
patch -p0 < ${MYFILESDIR}/buildpython4android_grp-py.diff
# Create a dummy /etc/group for grp.py to work
mkdir Etc
echo -e "root:x:0:root\nshell:x:2000:shell" > Etc/group

# 11) And now pack together our Android
rm -f python.tgz
tar czf python.tgz *
mv python.tgz ../../../python4android-${PYMINVER}-${ANDRO_PROC}-${ANDRO_API}.tgz

# Done. You may remove the temporary directories now.

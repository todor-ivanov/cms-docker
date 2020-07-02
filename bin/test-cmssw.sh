#!/bin/bash -ex
RELEASE_INST_DIR=/cvmfs/cms-ib.cern.ch
if [ "$WORKSPACE" = "" ] ; then export WORKSPACE=$(/bin/pwd) ; fi
cd $WORKSPACE

ls /cvmfs/cms-ib.cern.ch >/dev/null 2>&1
ls /cvmfs/cms.cern.ch >/dev/null 2>&1
GET_CMD="wget -q -O"
if wget --help >/dev/null 2>&1 ; then
  $GET_CMD cmsos https://raw.githubusercontent.com/cms-sw/cms-common/master/common/cmsos
else
  GET_CMD="curl -s -k -L -o"
  $GET_CMD cmsos https://raw.githubusercontent.com/cms-sw/cms-common/master/common/cmsos
fi
chmod +x cmsos
HOST_CMS_ARCH=$(./cmsos 2>/dev/null)
$GET_CMD bootstrap.sh http://cmsrep.cern.ch/cmssw/bootstrap.sh

INVALID_ARCHS='slc7_aarch64_gcc493 slc7_aarch64_gcc530'
export CMSSW_GIT_REFERENCE=/cvmfs/cms.cern.ch/cmssw.git.daily
week=week$(ls -d ${RELEASE_INST_DIR}/nweek-* | head -1 | sed 's|.*\(.\)$|\1%2|' | bc)
rpm_repo="cms.$week"
rm -rf inst; mkdir inst; cd inst
$GET_CMD archs http://cmsrep.cern.ch/cgi-bin/repos/${rpm_repo}
parch=""
touch $WORKSPACE/res.txt
for arch in $(grep ">${HOST_CMS_ARCH}_" archs |  sed "s|.*>${HOST_CMS_ARCH}_|${HOST_CMS_ARCH}_|;s|<.*||") ; do
  export SCRAM_ARCH=$arch
  cd $WORKSPACE/inst
  echo ${SCRAM_ARCH} >> $WORKSPACE/res.txt
  if [ $(echo ${INVALID_ARCHS} | tr ' ' '\n' | grep "^${arch}$" | wc -l) -gt 0 ] ; then
    echo ${SCRAM_ARCH}.SKIP >> $WORKSPACE/res.txt
    continue
  fi
  [ "${parch}" != "" ] && rm -rf ${parch}
  parch="${arch}"
  rm -rf ./$SCRAM_ARCH ; mkdir -p ./$SCRAM_ARCH
  cd ./$SCRAM_ARCH
  touch cmssw.rel
  $(source /cvmfs/cms.cern.ch/cmsset_default.sh >/dev/null 2>&1; scram -a $SCRAM_ARCH list -c CMSSW | grep -v '/cmssw-patch/' | grep ' CMSSW_' >cmssw.rel) || true
  cat cmssw.rel
  boot_repo=${rpm_repo}
  cmssw_ver=""
  for v in $(grep ${RELEASE_INST_DIR}/${week}/ cmssw.rel | grep '_[0-9][0-9]*_X_' | awk '{print $3}') ; do
    if [ -e $v/build-errors ] ; then continue ; fi
    cmssw_ver=$(basename $v)
  done
  if [ "${cmssw_ver}" = "" ] ; then
    cmssw_ver=$(grep /cvmfs/cms.cern.ch/ cmssw.rel | tail -1 | awk '{print $2}' || true)
    boot_repo="cms"
  fi
  if ! sh -ex $WORKSPACE/bootstrap.sh -r ${boot_repo} -a $SCRAM_ARCH setup ; then
    echo ${SCRAM_ARCH}.BOOT.ERR >> $WORKSPACE/res.txt
    continue
  fi
  echo ${SCRAM_ARCH}.BOOT.OK >> $WORKSPACE/res.txt
  if [ "${cmssw_ver}" = "" ] ; then
    echo "Warnings: No CMSSW version available for $SCRAM_ARCH"
    continue
  fi
  echo "Found release: ${cmssw_ver}"
  INSTALL_PACKAGES="$($WORKSPACE/inst/$SCRAM_ARCH/common/cmspkg -a $SCRAM_ARCH search gcc-fixincludes | sed 's| .*||' | grep 'gcc-fixincludes' | sort | tail -1)"
  $WORKSPACE/inst/$SCRAM_ARCH/common/cmspkg -a $SCRAM_ARCH install -y cms+cmssw+${cmssw_ver}
  if [ "${INSTALL_PACKAGES}" != "" ] ; then
    $WORKSPACE/inst/$SCRAM_ARCH/common/cmspkg -a $SCRAM_ARCH install -y ${INSTALL_PACKAGES}
  fi
  export cmssw_ver
  (
    source $WORKSPACE/inst/$SCRAM_ARCH/cmsset_default.sh >/dev/null 2>&1
    scram -a $SCRAM_ARCH project ${cmssw_ver}
    cd ${cmssw_ver}
    eval `scram run -sh` >/dev/null 2>&1
    USE_GIT=false
    if git cms-addpkg FWCore/Version >/dev/null 2>&1 ; then USE_GIT=true ; fi
    for p in FWCore/PrescaleService FWCore/SharedMemory FWCore/Framework DataFormats/Common DataFormats/StdDictionaries CondFormats/HIObjects ; do
      [ -e $CMSSW_RELEASE_BASE/src/$p ] || continue
      if $USE_GIT  ; then
        git cms-addpkg $p
      else
        mkdir -p $CMSSW_BASE/src/$p
        cp -r $CMSSW_RELEASE_BASE/src/$p/* $CMSSW_BASE/src/$p/
      fi
    done
    if scram build -j $(nproc) ; then
      echo ${SCRAM_ARCH}.${cmssw_ver}.OK >> $WORKSPACE/res.txt
    else
      echo ${SCRAM_ARCH}.${cmssw_ver}.ERR >> $WORKSPACE/res.txt
    fi
  )
  rm -rf $SCRAM_ARCH
done
[ "${parch}" != "" ] && rm -rf ${parch}
cat $WORKSPACE/res.txt
if [ $(grep '\.ERR$' $WORKSPACE/res.txt | wc -l) -gt 0 ] ; then exit 1 ; fi
echo "ALL_OK"

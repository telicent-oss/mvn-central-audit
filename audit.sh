#!/usr/bin/env bash

SCRIPT_DIR=$(dirname "${BASH_SOURCE[0]}")
SCRIPT_DIR=$(cd "${SCRIPT_DIR}" && pwd)

STEP=${1:-1}

function log() {
    echo -n "[$(date)]"
    echo -n " $1: "
    shift
    echo $*
}

function info() {
    log "INFO" $*
}

function warn() {
    log "WARN" $* 1>&2
}

function jsonWarn() {
  local TARGET=$1
  local MSG=$2
  echo "{ \"warnings\": [ \"${MSG}\" ]}" >> ${OUTPUT_DIR}/${TARGET}-warnings.json
}

function error() {
    log "ERROR" $* 1>&2
}

function blankLine() {
    echo ""
}

function abort() {
    local RET=$1
    shift
    error $*
    exit ${RET}
}

function requireCommands() {
  local COMMAND=""
  for COMMAND in $*; do
    if ! command -v ${COMMAND} >/dev/null 2>&1; then
      abort 126 "Required command ${COMMAND} not found"
    fi
  done
}

function md5hash() {
  local INPUT=$1
  if command -v md5 >/dev/null 2>&1; then
    echo "${INPUT}" | md5
  elif command -v md5sum >/dev/null 2>&1; then
    echo "${INPUT}" | md5sum | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    echo "${INPUT}" | openssl md5 | awk '{print $2}'
  else
    abort 126 "No suitable command to calculate a MD5 hash available"
  fi
}

# Check necessary commands are present
requireCommands mvn xidel jq awk printf echo rm read grep sed cat tr

function aborted() {
    abort 127 "Aborted due to user/OS interrupt"
}

trap aborted SIGINT SIGTERM SIGQUIT

function bytesToHuman() {
    local b=${1:-0}
    local d=''
    local s=0
    local S=(Bytes {K,M,G,T,E,P,Y,Z}B)
    while ((b >= 1000)); do
        d="$(printf ".%02d" $((b % 1000 * 100 / 1000)))"
        b=$((b / 1000))
        let s++
    done
    echo "$b$d ${S[$s]}"
}

function classify() {
  local FILE=""
  local SIZE=""
  local CLASSIFIER=""
  local EXT=""
  while read -r INPUT; do
    FILE=$(echo "${INPUT}" | awk '{print $1}')
    SIZE=$(echo "${INPUT}" | awk '{print $2}')
    EXT=${FILE##*.}
    if [ "${EXT}" == "asc" ]; then
      CLASSIFIER="signature"
      EXT="asc"
    elif [ "${EXT}" == "pom" ]; then
      CLASSIFIER="pom"
      EXT="pom"
    else
      CLASSIFIER=${FILE##*-}
      CLASSIFIER=${CLASSIFIER%%.*}
      case "${CLASSIFIER}" in 
        "javadoc" | "sources" | "test-sources" | "tests" | "cyclonedx")
          ;;
        *)
          CLASSIFIER="jar"
          ;;
      esac
    fi
    echo "${FILE}" "${SIZE}" "${CLASSIFIER}" "${EXT}"
  done
}

if [ -z "${OUTPUT_DIR}" ]; then
  OUTPUT_DIR="${TMPDIR:-/tmp/}$(md5hash "$PWD")"
fi
OUTPUT_DIR=${OUTPUT_DIR%/}
if ! mkdir -p ${OUTPUT_DIR}/; then
  abort 1 "Failed to create temporary output directory ${OUTPUT_DIR}"
fi
info "Maven Project Directory is ${PWD}"
if [ -n "${MAVEN_ARGS}" ]; then
  info "Additional Maven Arguments are ${MAVEN_ARGS}"
fi
info "Temporary Output Files will be written to $(cd ${OUTPUT_DIR} && pwd)"

# Firstly verify that this is a Maven project directory
blankLine
info "Step 1: Validate Maven Project Directory"
if [ ${STEP} -le 1 ]; then
    if [ ! -f "pom.xml" ]; then
    abort 1 "No pom.xml found in the current directory"
    fi
    info "Validated that current directory is a Maven project directory"
else
    info "Skipped at user request"
fi

# Secondly verify that the Maven project uses Maven Central publishing plugin
blankLine
info "Step 2: Validate Maven Central Publishing Plugin used"
if [ ${STEP} -le 2 ]; then
    if ! mvn help:effective-pom | grep central-publishing-maven-plugin >/dev/null 2>&1; then
      abort 2 "pom.xml does not appear to use Maven Central publishing plugin"
    fi
    info "Validated that Maven project uses Maven Central publishing plugin"
else
    info "Skipped at user request"
fi

# Determine the list of modules
blankLine
info "Step 3: Quick Building the Maven Project"
if [ ${STEP} -le 3 ]; then
    info "Quick building the Maven Project (skipping tests, GPG signing, CycloneDX SBOMs, Javadoc, Source and Delombok)"
    if ! mvn clean install -DskipTests -Dgpg.skip -Dcyclonedx.skip -Dmaven.javadoc.skip -Dmaven.source.skip -Dlombok.delombok.skip ${MAVEN_ARGS} > "${OUTPUT_DIR}/quick-build.log" 2>&1 ; then
      abort 3 "Failed to quick build the Maven project"
    fi
    info "Maven project quick builds OK"
else
    info "Skipped at user request"
fi
blankLine
info "Step 4: Determining Maven Modules"
if [ ${STEP} -le 4 ]; then
    info "Detecting Maven Modules..."
    if ! mvn exec:exec -Dexec.executable=echo -Dexec.args='${project.artifactId}' -q > ${OUTPUT_DIR}/maven-modules.txt; then
      abort 4 "Failed to detect Maven Modules"
    fi
else
    info "Skipped at user request"
fi
if [ ! -f "${OUTPUT_DIR}/maven-modules.txt" ]; then
  abort 4 "No Maven Modules file, you may need to re-run this script from an earlier step"
fi
TOTAL_MODULES=$(wc -l ${OUTPUT_DIR}/maven-modules.txt | awk '{print $1}' | tr -d ' ')
info "Found ${TOTAL_MODULES} Maven modules in this project"

# For each module determine whether or not it is published
blankLine
info "Step 5: Determining which Maven Modules are Published"
HASHES_PER_FILE=0
if [ ${STEP} -le 5 ]; then
  rm -f ${OUTPUT_DIR}/published-maven-modules.txt >/dev/null 2>&1
  while IFS= read -r -u3 MODULE; do
    rm -f ${OUTPUT_DIR}/${MODULE}-effective-pom.xml >/dev/null 2>&1
    info "Checking whether Maven Module ${MODULE} is published to Maven central..."
    mvn help:effective-pom -pl :${MODULE} -Doutput=${OUTPUT_DIR}/${MODULE}-effective-pom.xml -q
    
    PUBLISHING=$(xidel -se "//plugin[artifactId='central-publishing-maven-plugin'][1]/configuration/skipPublishing" ${OUTPUT_DIR}/${MODULE}-effective-pom.xml 2>/dev/null | head -n 1)
    if [ -z "${PUBLISHING}" ]; then
        PUBLISHING=$(mvn exec:exec -Dexec.executable=echo -Dexec.args='${skipPublishing}' -pl :${MODULE} -q)
    fi

    if [ "${PUBLISHING}" == "true" ]; then
        warn "Detected Maven Module ${MODULE} skips publishing to Maven Central"
    else
        echo ${MODULE} >> ${OUTPUT_DIR}/published-maven-modules.txt
        info "Maven Module ${MODULE} is published to Maven Central"
    fi

    if [ ${HASHES_PER_FILE} -eq 0 ]; then
      CHECKSUMS=$(xidel -se "//plugin[artifactId='central-publishing-maven-plugin'][1]/configuration/checksums" ${OUTPUT_DIR}/${MODULE}-effective-pom.xml 2>/dev/null | head -n 1)
      if [ "${CHECKSUMS}" == "required" ]; then
        HASHES_PER_FILE=2
      elif [ "${CHECKSUMS}" == "none" ]; then
        HASHES_PER_FILE=0
      else
        HASHES_PER_FILE=4
      fi
      echo ${HASHES_PER_FILE} > ${OUTPUT_DIR}/hashes-per-file
    fi
  done 3< ${OUTPUT_DIR}/maven-modules.txt
else
    info "Skipped at user request"
    HASHES_PER_FILE=$(cat ${OUTPUT_DIR}/hashes-per-file)
    if [ -z "${HASHES_PER_FILE}" ]; then
      HASHES_PER_FILE=4
    fi
fi

if [ ! -f "${OUTPUT_DIR}/published-maven-modules.txt" ]; then
  abort 5 "No published Maven modules file found in output directory, you may need to re-run this script from an earlier step"
fi
PUBLISHED_MODULES=$(wc -l ${OUTPUT_DIR}/published-maven-modules.txt | awk '{print $1}' | tr -d ' ')
info "${PUBLISHED_MODULES}/${TOTAL_MODULES} modules are published to Maven Central"
if [ ${PUBLISHED_MODULES} -eq 0 ]; then
  abort 5 "No modules are published to Maven Central"
fi
info "Maven Project will generate ${HASHES_PER_FILE} hash files per release file"

# Next we want to dry run deployment to see what bundles would be generated
# NB - Central Publishing Plugin doesn't have a dry-run option, best we can do is autoPublish=false and set a dud
#      centralBaseUrl so it doesn't actually upload to real Maven Central
# This also means we don't bother checking for the mvn command to fail here because we intend it to fail
blankLine
info "Step 6: Maven Deploy Dry Run"
if [ ${STEP} -le 6 ]; then
    info "Dry running mvn deploy (with tests skipped) to audit publishing bundle files..."
    mvn deploy -DskipTests -DautoPublish=false -DcentralBaseUrl=https://localhost ${MAVEN_ARGS} >${OUTPUT_DIR}/deploy-dry-run.log 2>&1
    info "Dry ran mvn deploy"
else
    info "Skipped at user request"
fi

# Determine bundle directories
blankLine
info "Step 7: Determining Bundle directories"
if [ ${STEP} -le 7 ]; then
  rm -f ${OUTPUT_DIR}/bundle-directories.txt >/dev/null 2>&1
  while IFS= read -r -u3 MODULE; do
    MODULE_INFO=$(mvn exec:exec -Dexec.executable=echo -Dexec.args='${project.groupId}:${project.artifactId}:${project.version}' -pl :${MODULE} -q)
    GROUP_ID=$(echo ${MODULE_INFO} | cut -d ':' -f 1)
    ARTIFACT_ID=$(echo ${MODULE_INFO} | cut -d ':' -f 2)
    VERSION=$(echo ${MODULE_INFO} | cut -d ':' -f 3)

    BUNDLE_DIR="target/central-deferred/$(echo "${GROUP_ID}" | tr -s '.' '/')/${ARTIFACT_ID}/${VERSION}/"
    info "Maven Module ${MODULE} has bundle directory ${BUNDLE_DIR}"
    echo "${MODULE} ${BUNDLE_DIR}" >> ${OUTPUT_DIR}/bundle-directories.txt
  done 3< ${OUTPUT_DIR}/published-maven-modules.txt

  FOUND_BUNDLE_DIRS=$(cat ${OUTPUT_DIR}/bundle-directories.txt | wc -l | tr -d ' ')
  if [ ${FOUND_BUNDLE_DIRS} -eq 0 ]; then
    abort 7 "Failed to find any bundle directories, review ${OUTPUT_DIR}/deploy-dry-run.log to understand why Deploy Dry Run failed to produce any bundles"
  fi
else
    info "Skipped at user request"
fi

# For each module inspect the bundle
TOTAL_FILES=0
TOTAL_FILE_SIZES=0
blankLine
info "Step 8: Auditing Maven Central bundles"
if [ ${STEP} -le 8 ]; then
  if [ ! -f "${OUTPUT_DIR}/published-maven-modules.txt" ]; then
    abort 8 "No bundle directories file found in output directory, you may need to re-run this script from an earlier step"
  fi

  while IFS= read -r -u3 BUNDLE; do
    MODULE=$(echo ${BUNDLE} | awk '{print $1}')
    blankLine
    info "Auditing Maven Central bundle for Maven Module ${MODULE}..."
    BUNDLE_DIR=$(echo ${BUNDLE} | awk '{print $2}')
    if [ ! -d "${BUNDLE_DIR}" ]; then
      error "Failed to find Bundle directory ${BUNDLE_DIR} for Maven Module ${MODULE}"
      continue
    fi
    rm -f ${OUTPUT_DIR}/${MODULE}-warnings.json >/dev/null 2>&1

    MODULE_FILES=$(ls "${BUNDLE_DIR}" | grep -v maven-metadata | wc -l | tr -d ' ')
    TOTAL_FILES=$(( ${TOTAL_FILES} + ${MODULE_FILES} ))
    info "Maven Module ${MODULE} publishes ${MODULE_FILES} release files"
    ls -lhS "${BUNDLE_DIR}" | grep -v maven-metadata | awk '{print $9 " " $5}' > ${OUTPUT_DIR}/${MODULE}-release-files.txt

    MODULE_FILE_SIZES=$(ls -l "${BUNDLE_DIR}" | grep -v maven-metadata | awk '{sum += $5} END {print sum}')
    TOTAL_FILE_SIZES=$(( ${TOTAL_FILE_SIZES} + ${MODULE_FILE_SIZES} ))
    info "Maven Module ${MODULE} publishes $(bytesToHuman ${MODULE_FILE_SIZES}) bytes of release files"

    # Warn if module is publishing more than 4MB of release files, this tends to imply fat JARs or some other artifacts
    # being produced that are large
    # NB - Maven Central uses 1000 as the kilo-convetion for its usage reporting
    if [ ${MODULE_FILE_SIZES} -gt 4000000 ]; then
      warn "Maven Module ${MODULE} produces more than 4MB of release files, top 5 files are as follows:"
      jsonWarn "${MODULE}" "Produces more than 4MB of release files"
      ls -lhS "${BUNDLE_DIR}" | grep -v maven-metadata | awk '{print $9 " " $5}' | head -n 6

      # Check for obvious causes of fat JARs
      if xidel -se "//plugin[artifactId='maven-shade-plugin']"; then
        warn "Maven Module ${MODULE} uses the Shade plugin, far JARs are generally a developer convenience and should not be published to Maven Central unless required by downstream consumers"
        jsonWarn "${MODULE}" "Uses the Shade plugin to produce fat JARs which most likely should not be published to Maven Central"
      fi
    fi

    # Warn if module is publishing tests or test-sources JARs
    if grep -F "tests.jar" ${OUTPUT_DIR}/${MODULE}-release-files.txt >/dev/null 2>&1; then
      if ! mvn dependency:tree 2>&1 | grep -F "${MODULE}:jar:tests:" >/dev/null 2>&1; then
        warn "Maven Module ${MODULE} publishes a tests classifier JAR that is not used as a dependency within this project, if this is not required by downstream consumers consider skipping test-jar packaging for this module"
        jsonWarn "${MODULE}" "Publishes a tests classifier JAR that is not used as a dependency within this project.  If not required by downstream consumers consider skipping test-jar packaging for this module"
      else
        info "Maven Module ${MODULE} publishes a tests classifier JAR that is an internal project dependency of other modules"
      fi
    fi
    if grep -F "test-sources.jar" ${OUTPUT_DIR}/${MODULE}-release-files.txt >/dev/null 2>&1; then
      if ! mvn dependency:tree 2>&1 | grep -F "${MODULE}:jar:tests:" >/dev/null 2>&1; then
        warn "Maven Module ${MODULE} publishes a test-sources JAR for a tests classifer JAR that is not used as a dependency within this project, if this is not required by downstream consumers consider skipping test-jar source attachement for this module"
        jsonWarn "${MODULE}" "Publishes a test-sources JAR for a tests classifier JAR that is not used as a dependency within this project.  If not required by downstream consuemrs consider skipping test-jar source attachment for this module"
      fi
    fi

    # Warn if multiple SBOM formats published
    SBOM_COUNT=$(ls "${BUNDLE_DIR}" | grep -F "cyclonedx" 2>&1 | grep -v -F ".asc" 2>&1 | wc -l | tr -d ' ')
    if [ ${SBOM_COUNT} -gt 1 ]; then
      warn "Maven Module ${MODULE} publishes multiple CycloneDX SBOM formats, SBOMs contain identical data so consider publishing only one format"
      jsonWarn "${MODULE}" "Publishes multiple CycloneDX SBOM formats, consider publishing only one format"
      ls "${BUNDLE_DIR}" | grep -F "cyclonedx" | grep -v -F ".asc"
    fi

    # Warn if no hashes produced if Maven Central plugin configured to none for hashes
    if [ ${HASHES_PER_FILE} -eq 0 ]; then
      if ! ls "${BUNDLE_DIR}" | grep -E "(sha1|md5|sha256|sha512)$" >/dev/null 2>&1; then
        warn "Maven Module ${MODULE} produces no hash files and Maven Central plugin not configured to produce them, this module may fail Maven Central validation as a result"
        jsonWarn "${MODULE}" "Produces no hash files and Maven Central plugin not configured to produce them, this module may fail Maven Central validation as a result"
      fi
    fi

    # Produce the JSON format output for this module which we'll later collate
    info "Preparing JSON report for module..."
    ls -lS "${BUNDLE_DIR}" | grep -v maven-metadata | awk '{print $9 " " $5}' \
        | sed '/^[[:blank:]]*$/d' \
        | classify > "${OUTPUT_DIR}/classified.txt"
    cat "${OUTPUT_DIR}/classified.txt" \
        | jq --raw-input --slurp -rc 'splits("\n") | split(" ") | select(. != []) | {file: .[0], size: .[1], classifier: .[2], type: .[3] }' \
        | jq --slurp "{ module: \"${MODULE}\", files: [.[]]}" \
        | jq --slurp 'reduce .[] as $item ({}; . * $item)' > ${OUTPUT_DIR}/${MODULE}-release-files.json
    if [ -f "${OUTPUT_DIR}/${MODULE}-warnings.json" ]; then
      info "Merging warnings into JSON report"
      mv ${OUTPUT_DIR}/${MODULE}-warnings.json ${OUTPUT_DIR}/${MODULE}-warnings.json.temp >/dev/null 2>&1
      cat ${OUTPUT_DIR}/${MODULE}-warnings.json.temp | jq --slurp '{ warnings: [ .[].warnings[]] }' > ${OUTPUT_DIR}/${MODULE}-warnings.json
      mv ${OUTPUT_DIR}/${MODULE}-release-files.json ${OUTPUT_DIR}/${MODULE}-release-files.json.temp >/dev/null 2>&1
      cat ${OUTPUT_DIR}/${MODULE}-release-files.json.temp ${OUTPUT_DIR}/${MODULE}-warnings.json \
        | jq --slurp 'reduce .[] as $item({}; . * $item)' > ${OUTPUT_DIR}/${MODULE}-release-files.json
    fi
    info "Maven Module ${MODULE} audit complete"

  done 3< ${OUTPUT_DIR}/bundle-directories.txt

  echo "${TOTAL_FILES}" > ${OUTPUT_DIR}/total-release-files
  echo "${TOTAL_FILE_SIZES}" > ${OUTPUT_DIR}/total-file-sizes
else
  if [ -f "${OUTPUT_DIR}/total-release-files" ]; then
    TOTAL_FILES=$(cat "${OUTPUT_DIR}/total-release-files")
  fi
  if [ -f "${OUTPUT_DIR}/total-file-sizes" ]; then
    TOTAL_FILE_SIZES=$(cat "${OUTPUT_DIR}/total-file-sizes")
  fi
  info "Skipped at user request"
fi
if [ "${TOTAL_FILES}" -eq 0 ] || [ "${TOTAL_FILE_SIZES}" -eq 0 ] || [ -z "${TOTAL_FILES}" ] || [ -z "${TOTAL_FILE_SIZES}" ]; then
  abort 8 "Failed to obtain total release files count and sizes, you may need to re-run this script from an earlier step"
fi

# Step 9 - Final Audit Report
blankLine
info "Step 9 - Produce Audit Report"
info "Maven Project publishes ${TOTAL_FILES} release files"
info "Maven Project publishes $(bytesToHuman ${TOTAL_FILE_SIZES}) bytes of release files"
# Bundles don't contain generated hashes so need to account for those
TOTAL_HASH_FILES=$(( (${TOTAL_FILES} / 2) * ${HASHES_PER_FILE}))
info "An additional ${TOTAL_HASH_FILES} hash files will also be published"
if [ ${HASHES_PER_FILE} -eq 4 ]; then
  warn "Central Publishing plugin is configured to publish all hashes which generates 2 additional hashes per release file than if you had configured <checksums>required</checksums> on the plugin"
elif [ ${HASHES_PER_FILE} -eq 0 ]; then
  warn "Central Publishing plugin is configured to publish no hashes, this means your build MUST generate the hashes themselves, if it does then the hash files are already included in the release files statistics"
fi
if [ ${HASHES_PER_FILE} -eq 4 ]; then
  # All four hashes (md5, sha1, sha256 and sha512 total 264 bytes)
  HASH_FILE_SIZES=$(( ${TOTAL_HASH_FILES} * 264 ))
else
  # Minimum required hashes (md5, sha1 total 72 bytes)
  HASH_FILE_SIZES=$(( ${TOTAL_HASH_FILES} * 72 ))
fi
info "Hash files will add an additional $(bytesToHuman ${HASH_FILE_SIZES}) bytes of hash files"

WARNINGS=$(cat ${OUTPUT_DIR}/*-release-files.json | jq -r '.warnings[]?' | wc -l | tr -d ' ')
if [ ${WARNINGS} -gt 0 ]; then
  warn "There are ${WARNINGS} warnings across the published modules, please review the audit report and see if any need addressing"
fi
blankLine
info "Total Files (including Hashes): $(( ${TOTAL_FILES} + ${TOTAL_HASH_FILES} ))"
info "Total Release Size (including Hashes): $(bytesToHuman $(( ${TOTAL_FILE_SIZES} + ${HASH_FILE_SIZES} )))"

# Produce the JSON format reports from the accumulated module reports
blankLine
cat ${OUTPUT_DIR}/*-release-files.json | jq --slurp -c '.[] | { modules: [.]}' \
  | jq --slurp "{releaseFiles: \"${TOTAL_FILES}\", releaseFilesSize: \"${TOTAL_FILE_SIZES}\", hashFiles: \"${TOTAL_HASH_FILES}\", hashFilesSize: \"${HASH_FILE_SIZES}\", totalFiles: \"$(( ${TOTAL_FILES} + ${TOTAL_HASH_FILES} ))\", totalSize: \"$(( ${TOTAL_FILE_SIZES} + ${HASH_FILE_SIZES} ))\", warnings: \"${WARNINGS}\", modules: [.[].modules[]]}" > ${OUTPUT_DIR}/audit-report.temp


# Compute per classifier sizes
cat ${OUTPUT_DIR}/audit-report.temp \
  | jq '[.modules[].files[]] | group_by(.classifier) | map([first.classifier, (map(.size | tonumber) | add), length]) | { classifiers: [(.[] | { classifier: .[0], size: .[1], files: .[2]}) ] } | .classifiers | sort_by(.size) | reverse | { classifiers: .}' > "${OUTPUT_DIR}/classifiers.json"
cat ${OUTPUT_DIR}/audit-report.temp ${OUTPUT_DIR}/classifiers.json | jq --slurp 'add' > ${OUTPUT_DIR}/audit-report.json

info "JSON Audit Report available as ${OUTPUT_DIR}/audit-report.json"
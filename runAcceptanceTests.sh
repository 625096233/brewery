#!/bin/bash

set -o errexit

# ======================================= FUNCTIONS START =======================================

# CLOUD FOUNDRY -- START

CLOUD_DOMAIN=${DOMAIN:-run.pivotal.io}
CLOUD_TARGET=api.${DOMAIN}

function login(){
    cf api | grep ${CLOUD_TARGET} || cf api ${CLOUD_TARGET} --skip-ssl-validation
    cf apps | grep OK || cf login
}

function app_domain(){
    D=`cf apps | grep $1 | tr -s ' ' | cut -d' ' -f 6 | cut -d, -f1`
    echo $D
}

function deploy_app(){
    deploy_app_with_name $1 $1
}

function deploy_zookeeper_app(){
    APP_DIR=$1
    APP_NAME=$1
    cd $APP_DIR
    cf push $APP_NAME --no-start
    APPLICATION_DOMAIN=`app_domain $APP_NAME`
    echo determined that application_domain for $APP_NAME is $APPLICATION_DOMAIN.
    cf env $APP_NAME | grep APPLICATION_DOMAIN || cf set-env $APP_NAME APPLICATION_DOMAIN $APPLICATION_DOMAIN
    cf env $APP_NAME | grep arguments || cf set-env $APP_NAME "spring.cloud.zookeeper.connectString" "$2:2181"
    cf restart $APP_NAME
    cd ..
}

function deploy_app_with_name(){
    APP_DIR=$1
    APP_NAME=$2
    cd $APP_DIR
    cf push $APP_NAME --no-start -f "manifest-${CLOUD_PREFIX}.yml"
    APPLICATION_DOMAIN=`app_domain $APP_NAME`
    echo determined that application_domain for $APP_NAME is $APPLICATION_DOMAIN.
    cf env $APP_NAME | grep APPLICATION_DOMAIN || cf set-env $APP_NAME APPLICATION_DOMAIN $APPLICATION_DOMAIN
    cf restart $APP_NAME
    cd ..
}

function deploy_app_with_name_parallel(){
    xargs -n 2 -P 4 bash -c 'deploy_app_with_name "$@"'
}

function deploy_service(){
    N=$1
    D=`app_domain $N`
    JSON='{"uri":"http://'$D'"}'
    cf create-user-provided-service $N -p $JSON
}

function reset(){
    app_name=$1
    echo "going to remove ${app_name} if it exists"
    cf apps | grep $app_name && cf d -f $app_name
    echo "deleted ${app_name}"
}
# CLOUD FOUNDRY -- FINISH


# Tails the log
function tail_log() {
    echo -e "\n\nLogs of [$1] jar app"
    if [[ -z "${CLOUD_FOUNDRY}" ]] ; then
        tail -n $NUMBER_OF_LINES_TO_LOG build/"$1".log || echo "Failed to open log"
    else
        cf logs "${CLOUD_PREFIX}-$1" --recent || echo "Failed to open log"
    fi
}

# Iterates over active containers and prints their logs to stdout
function print_logs() {
    echo -e "\n\nSomething went wrong... Printing logs:\n"
    if [[ -z "${CLOUD_FOUNDRY}" ]] ; then
            docker ps | sed -n '1!p' > /tmp/containers.txt
            while read field1 field2 field3; do
              echo -e "\n\nContainer name [$field2] with id [$field1] logs: \n\n"
              docker logs --tail=$NUMBER_OF_LINES_TO_LOG -t $field1
            done < /tmp/containers.txt
    fi
    tail_log "brewing"
    tail_log "zuul"
    tail_log "presenting"
    tail_log "reporting"
    tail_log "ingredients"
    tail_log "config-server"
    tail_log "eureka"
    tail_log "discovery"
    tail_log "zookeeper"
    tail_log "zipkin-server"
}

# ${RETRIES} number of times will try to netcat to passed port $1 and host $2
function netcat_port() {
    local PASSED_HOST="${2:-$HEALTH_HOST}"
    local READY_FOR_TESTS=1
    for i in $( seq 1 "${RETRIES}" ); do
        sleep "${WAIT_TIME}"
        nc -v -z -w 1 $PASSED_HOST $1 && READY_FOR_TESTS=0 && break
        echo "Fail #$i/${RETRIES}... will try again in [${WAIT_TIME}] seconds"
    done
    return $READY_FOR_TESTS
}

# ${RETRIES} number of times will try to netcat to passed port $1 and localhost
function netcat_local_port() {
    netcat_port $1 "127.0.0.1"
}

# ${RETRIES} number of times will try to curl to /health endpoint to passed port $1 and host $2
function curl_health_endpoint() {
    local PASSED_HOST="${2:-$HEALTH_HOST}"
    local READY_FOR_TESTS=1
    for i in $( seq 1 "${RETRIES}" ); do
        sleep "${WAIT_TIME}"
        curl -m 5 "${PASSED_HOST}:$1/health" && READY_FOR_TESTS=0 && break
        echo "Fail #$i/${RETRIES}... will try again in [${WAIT_TIME}] seconds"
    done
    return $READY_FOR_TESTS
}

# ${RETRIES} number of times will try to curl to /health endpoint to passed port $1 and localhost
function curl_local_health_endpoint() {
    curl_health_endpoint $1 "127.0.0.1"
}

# Runs the `java -jar` for given application $1 and system properties $2
function java_jar() {
    local APP_JAVA_PATH=$1/build/libs
    local EXPRESSION="nohup ${JAVA_PATH_TO_BIN}java $2 $MEM_ARGS -jar $APP_JAVA_PATH/*.jar >$APP_JAVA_PATH/nohup.log &"
    echo -e "\nTrying to run [$EXPRESSION]"
    eval $EXPRESSION
    pid=$!
    echo $pid > $APP_JAVA_PATH/app.pid
    echo -e "[$1] process pid is [$pid]"
    echo -e "System props are [$2]"
    echo -e "Logs are under [build/$1.log] or from nohup [$APP_JAVA_PATH/nohup.log]\n"
    return 0
}

# Starts the main brewery apps with given system props $1
function start_brewery_apps() {
    local REMOTE_DEBUG="-agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address"
    java_jar "presenting" "$1 $REMOTE_DEBUG=8991"
    java_jar "brewing" "$1 $REMOTE_DEBUG=8992"
    java_jar "zuul" "$1 $REMOTE_DEBUG=8993"
    java_jar "ingredients" "$1 $REMOTE_DEBUG=8994"
    java_jar "reporting" "$1 $REMOTE_DEBUG=8995"
    return 0
}

function kill_and_log() {
    kill -9 $(cat "$1"/build/libs/app.pid) && echo "Killed $1" || echo "Can't find $1 in running processes"
}
# Kills all started aps
function kill_all_apps() {
    if [[ -z "${CLOUD_FOUNDRY}" ]] ; then
            echo `pwd`
            kill_and_log "brewing"
            kill_and_log "zuul"
            kill_and_log "presenting"
            kill_and_log "ingredients"
            kill_and_log "reporting"
            kill_and_log "config-server"
            kill_and_log "eureka"
            kill_and_log "zookeeper"
            kill_and_log "zipkin-server"
            if [[ -z "${KILL_NOW_APPS}" ]] ; then
                docker kill $(docker ps -q) || echo "No running docker containers are left"
            fi
        else
            reset "${CLOUD_PREFIX}-brewing" || echo "Failed to kill the app"
            reset "${CLOUD_PREFIX}-zuul" || echo "Failed to kill the app"
            reset "${CLOUD_PREFIX}-presenting" || echo "Failed to kill the app"
            reset "${CLOUD_PREFIX}-ingredients" || echo "Failed to kill the app"
            reset "${CLOUD_PREFIX}-reporting" || echo "Failed to kill the app"
            yes | cf delete-service "${CLOUD_PREFIX}-config-server" || echo "Failed to kill the app"
            reset "${CLOUD_PREFIX}-config-server" || echo "Failed to kill the app"
            yes | cf delete-service "${CLOUD_PREFIX}-discovery" || echo "Failed to kill the app"
            reset "${CLOUD_PREFIX}-discovery" || echo "Failed to kill the app"
            reset "${CLOUD_PREFIX}-zipkin-server" || echo "Failed to kill the app"
            reset "${CLOUD_PREFIX}-zipkin-web" || echo "Failed to kill the app"
            yes | cf delete-orphaned-routes || echo "Failed to delete routes"
    fi
    return 0
}

# Kills all started aps if the switch is on
function kill_all_apps_if_switch_on() {
    if [[ $KILL_AT_THE_END ]]; then
        echo -e "\n\nKilling all the apps"
        kill_all_apps
    else
        echo -e "\n\nNo switch to kill the apps turned on"
        return 0
    fi
    return 0
}

function print_usage() {
cat <<EOF

USAGE:

You can use the following options:

-t|--whattotest  - define what you want to test (e.g. SLEUTH, ZOOKEEPER)
-v|--version - which version of BOM do you want to use? Defaults to Brixton snapshot
-h|--healthhost - what is your health host? where is docker? defaults to localhost
-l|--numberoflines - how many lines of logs of your app do you want to print? Defaults to 1000
-r|--reset - do you want to reset the git repo of brewery? Defaults to "no"
-k|--killattheend - should kill all the running apps at the end of execution? Defaults to "no"
-n|--killnow - should not run all the logic but only kill the running apps? Defaults to "no"
-x|--skiptests - should skip running of e2e tests? Defaults to "no"
-s|--skipbuilding - should skip building of the projects? Defaults to "no"
-c|--cloudfoundry - should run tests for cloud foundry? Defaults to "no"
-o|--deployonlyapps - should deploy only the brewery business apps instead of the infra too? Defaults to "no"
-d|--skipdeployment - should skip deployment of apps? Defaults to "no"
-p|--cloudfoundryprefix - provides the prefix to the brewery app name. Defaults to 'brewery'

EOF
}

# ======================================= FUNCTIONS END =======================================


# ======================================= VARIABLES START =======================================
CURRENT_DIR=`pwd`
REPO_URL="${REPO_URL:-https://github.com/spring-cloud-samples/brewery.git}"
REPO_BRANCH="${REPO_BRANCH:-master}"
if [[ -d acceptance-tests ]]; then
  REPO_LOCAL="${REPO_LOCAL:-.}"
else
  REPO_LOCAL="${REPO_LOCAL:-brewery}"
fi
WAIT_TIME="${WAIT_TIME:-5}"
RETRIES="${RETRIES:-70}"
DEFAULT_VERSION="${DEFAULT_VERSION:-Brixton.BUILD-SNAPSHOT}"
DEFAULT_HEALTH_HOST="${DEFAULT_HEALTH_HOST:-127.0.0.1}"
DEFAULT_NUMBER_OF_LINES_TO_LOG="${DEFAULT_NUMBER_OF_LINES_TO_LOG:-1000}"
SHOULD_START_RABBIT="${SHOULD_START_RABBIT:-yes}"
JAVA_PATH_TO_BIN="${JAVA_HOME}/bin/"
if [[ -z "${JAVA_HOME}" ]] ; then
    JAVA_PATH_TO_BIN=""
fi
LOCALHOST="127.0.0.1"
MEM_ARGS="-Xmx128m -Xss1024k"
CLOUD_PREFIX="brewery"

BOM_VERSION_PROP_NAME="BOM_VERSION"

# ======================================= VARIABLES END =======================================


# ======================================= PARSING ARGS START =======================================
if [[ $# == 0 ]] ; then
    print_usage
    exit 0
fi

while [[ $# > 0 ]]
do
key="$1"
case $key in
    -t|--whattotest)
    WHAT_TO_TEST="$2"
    shift # past argument
    ;;
    -v|--version)
    VERSION="$2"
    shift # past argument
    ;;
    -h|--healthhost)
    HEALTH_HOST="$2"
    shift # past argument
    ;;
    -l|--numberoflines)
    NUMBER_OF_LINES_TO_LOG="$2"
    shift # past argument
    ;;
    -r|--reset)
    RESET="yes"
    ;;
    -k|--killattheend)
    KILL_AT_THE_END="yes"
    ;;
    -n|--killnow)
    KILL_NOW="yes"
    ;;
    -na|--killnowapps)
    KILL_NOW="yes"
    KILL_NOW_APPS="yes"
    ;;
    -x|--skiptests)
    NO_TESTS="yes"
    ;;
    -s|--skipbuilding)
    SKIP_BUILDING="yes"
    ;;
    -c|--cloudfoundry)
    CLOUD_FOUNDRY="yes"
    ;;
    -o|--deployonlyapps)
    DEPLOY_ONLY_APPS="yes"
    ;;
    -d|--skipdeployment)
    SKIP_DEPLOYMENT="yes"
    ;;
    -p|--cloudfoundryprefix)
    CLOUD_PREFIX="$2"
    shift # past argument
    ;;
    --help)
    print_usage
    exit 0
    ;;
    *)
    echo "Invalid option: [$1]"
    print_usage
    exit 1
    ;;
esac
shift # past argument or value
done


[[ -z "${WHAT_TO_TEST}" ]] && WHAT_TO_TEST=ZOOKEEPER
[[ -z "${VERSION}" ]] && VERSION="${DEFAULT_VERSION}"
[[ -z "${HEALTH_HOST}" ]] && HEALTH_HOST="${DEFAULT_HEALTH_HOST}"
[[ -z "${NUMBER_OF_LINES_TO_LOG}" ]] && NUMBER_OF_LINES_TO_LOG="${DEFAULT_NUMBER_OF_LINES_TO_LOG}"

HEALTH_PORTS=('9991' '9992' '9993' '9994' '9995')
HEALTH_ENDPOINTS="$( printf "http://${LOCALHOST}:%s/health " "${HEALTH_PORTS[@]}" )"
ACCEPTANCE_TEST_OPTS="${ACCEPTANCE_TEST_OPTS:--DLOCAL_URL=http://${HEALTH_HOST}}"

cat <<EOF

Running tests with the following parameters

HEALTH_HOST=${HEALTH_HOST}
WHAT_TO_TEST=${WHAT_TO_TEST}
VERSION=${VERSION}
NUMBER_OF_LINES_TO_LOG=${NUMBER_OF_LINES_TO_LOG}
KILL_AT_THE_END=${KILL_AT_THE_END}
KILL_NOW=${KILL_NOW}
KILL_NOW_APPS=${KILL_NOW_APPS}
NO_TESTS=${NO_TESTS}
SKIP_BUILDING=${SKIP_BUILDING}
SHOULD_START_RABBIT=${SHOULD_START_RABBIT}
ACCEPTANCE_TEST_OPTS=${ACCEPTANCE_TEST_OPTS}
CLOUD_FOUNDRY=${CLOUD_FOUNDRY}
DEPLOY_ONLY_APPS=${DEPLOY_ONLY_APPS}
SKIP_DEPLOYMENT=${SKIP_DEPLOYMENT}
CLOUD_PREFIX=${CLOUD_PREFIX}

EOF

# ======================================= PARSING ARGS END =======================================

# ======================================= EXPORTING VARS START =======================================
export WHAT_TO_TEST=$WHAT_TO_TEST
export VERSION=$VERSION
export HEALTH_HOST=$HEALTH_HOST
export WAIT_TIME=$WAIT_TIME
export RETRIES=$RETRIES
export BOM_VERSION_PROP_NAME=$BOM_VERSION_PROP_NAME
export NUMBER_OF_LINES_TO_LOG=$NUMBER_OF_LINES_TO_LOG
export KILL_AT_THE_END=$KILL_AT_THE_END
export KILL_NOW_APPS=$KILL_NOW_APPS
export LOCALHOST=$LOCALHOST
export MEM_ARGS=$MEM_ARGS
export SHOULD_START_RABBIT=$SHOULD_START_RABBIT
export ACCEPTANCE_TEST_OPTS=$ACCEPTANCE_TEST_OPTS
export CLOUD_FOUNDRY=$CLOUD_FOUNDRY
export DEPLOY_ONLY_APPS=$DEPLOY_ONLY_APPS
export SKIP_DEPLOYMENT=$SKIP_DEPLOYMENT
export CLOUD_PREFIX=$CLOUD_PREFIX
export JAVA_PATH_TO_BIN=$JAVA_PATH_TO_BIN

export -f login
export -f app_domain
export -f deploy_app
export -f deploy_zookeeper_app
export -f deploy_app_with_name
export -f deploy_app_with_name_parallel
export -f deploy_service
export -f reset
export -f tail_log
export -f print_logs
export -f netcat_port
export -f netcat_local_port
export -f curl_health_endpoint
export -f curl_local_health_endpoint
export -f java_jar
export -f start_brewery_apps
export -f kill_all_apps
export -f kill_and_log

# ======================================= EXPORTING VARS END =======================================

# ======================================= Kill all apps and exit if switch set =======================================
if [[ $KILL_NOW ]] ; then
    echo -e "\nKilling all apps"
    kill_all_apps
    exit 0
fi

# ======================================= Clone or update the brewery repository =======================================
if [[ ! -e "${REPO_LOCAL}/.git" ]]; then
    git clone "${REPO_URL}" "${REPO_LOCAL}"
    cd "${REPO_LOCAL}"
else
    cd "${REPO_LOCAL}"
    if [[ $RESET ]]; then
        git reset --hard
        git pull "${REPO_URL}" "${REPO_BRANCH}"
    fi
fi


# ======================================= Building the apps =======================================
echo -e "\nAppending if not present the following entry to gradle.properties\n"

# Update the desired BOM version
grep "${BOM_VERSION_PROP_NAME}=${VERSION}" gradle.properties || echo -e "\n${BOM_VERSION_PROP_NAME}=${VERSION}" >> gradle.properties

echo -e "\n\nUsing the following gradle.properties"
cat gradle.properties

echo -e "\n\n"

# Build the apps
APP_BUILDING_RETRIES=3
APP_WAIT_TIME=1
APP_FAILED="yes"
if [[ -z "${SKIP_BUILDING}" ]] ; then
    for i in $( seq 1 "${APP_BUILDING_RETRIES}" ); do
          ./gradlew clean build --parallel --no-daemon && APP_FAILED="no" && break
          echo "Fail #$i/${APP_BUILDING_RETRIES}... will try again in [${APP_WAIT_TIME}] seconds"
    done
else
    APP_FAILED="no"
fi

if [[ "${APP_FAILED}" == "yes" ]] ; then
    echo -e "\n\nFailed to build the apps!"
    exit 1
fi


# ======================================= Deploying apps locally or to cloud foundry =======================================
INITIALIZATION_FAILED="yes"
if [[ -z "${CLOUD_FOUNDRY}" ]] ; then
        if [[ -z "${SKIP_DEPLOYMENT}" ]] ; then
            . ./docker-compose-$WHAT_TO_TEST.sh && INITIALIZATION_FAILED="no"
        else
          INITIALIZATION_FAILED="no"
        fi
    else
        if [[ -z "${SKIP_DEPLOYMENT}" ]] ; then
          . ./cloud-foundry-$WHAT_TO_TEST.sh && INITIALIZATION_FAILED="no"
        else
          INITIALIZATION_FAILED="no"
        fi
fi

if [[ "${INITIALIZATION_FAILED}" == "yes" ]] ; then
    echo -e "\n\nFailed to initialize the apps!"
    print_logs
    kill_all_apps_if_switch_on
    exit 1
fi

# ======================================= Checking if apps are booted =======================================
if [[ -z "${CLOUD_FOUNDRY}" ]] ; then

        if [[ -z "${SKIP_DEPLOYMENT}" ]] ; then
            # Wait for the apps to boot up
            APPS_ARE_RUNNING="no"

            echo -e "\n\nWaiting for the apps to boot for [$(( WAIT_TIME * RETRIES ))] seconds"
            for i in $( seq 1 "${RETRIES}" ); do
                sleep "${WAIT_TIME}"
                curl -m 5 ${HEALTH_ENDPOINTS} && APPS_ARE_RUNNING="yes" && break
                echo "Fail #$i/${RETRIES}... will try again in [${WAIT_TIME}] seconds"
            done

            if [[ "${APPS_ARE_RUNNING}" == "no" ]] ; then
                echo "\n\nFailed to boot the apps!"
                print_logs
                kill_all_apps_if_switch_on
                exit 1
            fi

            # Wait for the apps to register in Service Discovery
            READY_FOR_TESTS="no"

            echo -e "\n\nChecking for the presence of all services in Service Discovery for [$(( WAIT_TIME * RETRIES ))] seconds"
            for i in $( seq 1 "${RETRIES}" ); do
                sleep "${WAIT_TIME}"
                curl -m 5 http://${LOCALHOST}:9991/health | grep presenting |
                    grep brewing | grep ingredients | grep reporting && READY_FOR_TESTS="yes" && break
                echo "Fail #$i/${RETRIES}... will try again in [${WAIT_TIME}] seconds"
            done

            if [[ "${READY_FOR_TESTS}" == "no" ]] ; then
                echo "\n\nThe apps failed to register in Service Discovery!"
                print_logs
                kill_all_apps_if_switch_on
                exit 1
            fi

            echo
        else
            echo "Skipping deployment"
            READY_FOR_TESTS="yes"
        fi
else
    READY_FOR_TESTS="yes"
    echo "\n\nSkipping the check if apps are booted"
fi

# ======================================= Running acceptance tests =======================================
TESTS_PASSED="no"

if [[ $NO_TESTS ]] ; then
    echo -e "\nSkipping end to end tests"
    kill_all_apps_if_switch_on
    exit 0
fi

if [[ "${READY_FOR_TESTS}" == "yes" ]] ; then
    echo -e "\n\nSuccessfully booted up all the apps. Proceeding with the acceptance tests"
    echo -e "\n\nRunning acceptance tests with the following parameters [-DWHAT_TO_TEST=${WHAT_TO_TEST} ${ACCEPTANCE_TEST_OPTS}]"
    ./gradlew :acceptance-tests:acceptanceTests "-DWHAT_TO_TEST=${WHAT_TO_TEST}" ${ACCEPTANCE_TEST_OPTS} --stacktrace --no-daemon --configure-on-demand && TESTS_PASSED="yes"
fi

# Check the result of tests execution
if [[ "${TESTS_PASSED}" == "yes" ]] ; then
    echo -e "\n\nTests passed successfully."
    kill_all_apps_if_switch_on
    exit 0
else
    echo -e "\n\nTests failed..."
    print_logs
    kill_all_apps_if_switch_on
    exit 1
fi

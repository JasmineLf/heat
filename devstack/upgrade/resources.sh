#!/bin/bash
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.

set -o errexit

source $GRENADE_DIR/grenaderc
source $GRENADE_DIR/functions

source $TOP_DIR/openrc admin admin
source $TOP_DIR/inc/ini-config

set -o xtrace

HEAT_USER=heat_grenade
HEAT_PROJECT=heat_grenade
HEAT_PASS=pass
DEFAULT_DOMAIN=default

function _heat_set_user {
    OS_TENANT_NAME=$HEAT_PROJECT
    OS_PROJECT_NAME=$HEAT_PROJECT
    OS_USERNAME=$HEAT_USER
    OS_PASSWORD=$HEAT_PASS
    OS_USER_DOMAIN_ID=$DEFAULT_DOMAIN
    OS_PROJECT_DOMAIN_ID=$DEFAULT_DOMAIN
}

function _config_tempest {
    conf_file=etc/tempest.conf
    iniset_multiline $conf_file service_available heat_plugin True
    iniset $conf_file heat_plugin username $OS_USERNAME
    iniset $conf_file heat_plugin password $OS_PASSWORD
    iniset $conf_file heat_plugin tenant_name $OS_PROJECT_NAME
    iniset $conf_file heat_plugin auth_url $OS_AUTH_URL
    iniset $conf_file heat_plugin user_domain_id $OS_USER_DOMAIN_ID
    iniset $conf_file heat_plugin project_domain_id $OS_PROJECT_DOMAIN_ID
    iniset $conf_file heat_plugin user_domain_name $OS_USER_DOMAIN_NAME
    iniset $conf_file heat_plugin project_domain_name $OS_PROJECT_DOMAIN_NAME
    iniset $conf_file heat_plugin region $OS_REGION_NAME
    iniset $conf_file heat_plugin auth_version $OS_IDENTITY_API_VERSION
}

function _write_heat_integrationtests {
    local upgrade_tests=$1
    cat > $upgrade_tests <<EOF
heat_tempest_plugin.tests.api
EOF
}

function _run_heat_api_tests {
    pushd $TARGET_RELEASE_DIR/tempest
    sed -i -e '/group_regex/c\group_regex=heat_tempest_plugin\\.tests\\.api\\.test_heat_api(?:\\.|_)([^_]+)' .stestr.conf

    # Run set of specified functional tests
    UPGRADE_TESTS=upgrade_tests.list
    _write_heat_integrationtests $UPGRADE_TESTS

    _config_tempest

    sudo UPPER_CONSTRAINTS_FILE=$TARGET_RELEASE_DIR/requirements/upper-constraints.txt \
    tox -evenv-tempest -- stestr --test-path=$TARGET_RELEASE_DIR/heat/heat_integrationtests \
    --top-dir=$TARGET_RELEASE_DIR/heat \
    --group_regex='heat_tempest_plugin\.tests\.api\.test_heat_api[._]([^_]+)' run \
    --whitelist-file $UPGRADE_TESTS
    popd
}

function _run_heat_create_tests {
    pushd $BASE_RELEASE_DIR/tempest
    _config_tempest
    # Old version of tempest is installed in grenade environment, so use
    # .testr.conf instead of .stestr.conf
    cat <<'EOF' >.testr.conf
[DEFAULT]
test_command=OS_STDOUT_CAPTURE=${OS_STDOUT_CAPTURE:-1} \
             OS_STDERR_CAPTURE=${OS_STDERR_CAPTURE:-1} \
             OS_TEST_TIMEOUT=${OS_TEST_TIMEOUT:-500} \
             OS_TEST_LOCK_PATH=${OS_TEST_LOCK_PATH:-${TMPDIR:-'/tmp'}} \
             ${PYTHON:-python} -m subunit.run discover -t ${OS_TOP_LEVEL:-./} \
             ${OS_TEST_PATH:-./tempest/test_discover} $LISTOPT $IDOPTION
test_id_option=--load-list $IDFILE
test_list_option=--list
group_regex=([^\.]*\.)*
EOF

    UPPER_CONSTRAINTS_FILE=$BASE_RELEASE_DIR/requirements/upper-constraints.txt tempest run --regex '(test_create_update.CreateStackTest|test_create_update.UpdateStackTest)'
    popd
}

function create {
    _run_heat_create_tests
    # creates a tenant for the server
    eval $(openstack project create -f shell -c id $HEAT_PROJECT)
    if [[ -z "$id" ]]; then
        die $LINENO "Didn't create $HEAT_PROJECT project"
    fi
    resource_save heat project_id $id
    local project_id=$id

    # creates the user, and sets $id locally
    eval $(openstack user create $HEAT_USER \
            --project $id \
            --password $HEAT_PASS \
            -f shell -c id)
    if [[ -z "$id" ]]; then
        die $LINENO "Didn't create $HEAT_USER user"
    fi
    resource_save heat user_id $id
    # with keystone v3 user created in a project is not assigned a role
    # https://bugs.launchpad.net/keystone/+bug/1662911
    openstack role add Member --user $id --project $project_id

    _heat_set_user

    local stack_name='grenadine'
    resource_save heat stack_name $stack_name
    local loc=`dirname $BASH_SOURCE`
    heat stack-create -f $loc/templates/random_string.yaml $stack_name
}

function verify {
    _heat_set_user
    local side="$1"
    if [[ "$side" = "post-upgrade" ]]; then
        _run_heat_api_tests
    fi
    stack_name=$(resource_get heat stack_name)
    heat stack-show $stack_name
    # TODO(sirushtim): Create more granular checks for Heat.
}

function verify_noapi {
    # TODO(sirushtim): Write tests to validate liveness of the resources
    # it creates during possible API downtime.
    :
}

function destroy {
    _heat_set_user
    heat stack-delete $(resource_get heat stack_name)

    source $TOP_DIR/openrc admin admin
    local user_id=$(resource_get heat user_id)
    local project_id=$(resource_get heat project_id)
    openstack user delete $user_id
    openstack project delete $project_id
}

# Dispatcher
case $1 in
    "create")
        create
        ;;
    "verify_noapi")
        verify_noapi
        ;;
    "verify")
        verify $2
        ;;
    "destroy")
        destroy
        ;;
esac

#!/bin/bash

if [[ -n $SONARQUBE_TOKEN ]]; then
    BASIC_AUTH="$SONARQUBE_TOKEN:"
else
    BASIC_AUTH="${SONARQUBE_USERNAME:-admin}:${SONARQUBE_PASSWORD:-admin}"
fi

# Access SonarQube api with admin credentials
function curlAdmin {
    curl -v -u "$BASIC_AUTH" "$@"
}

function createJenkinsWebhook {
  curlAdmin -X POST "$BASE_URL/api/webhooks/create" -d "name=jenkins&url=http://jenkins:8080/sonarqube-webhook/"
}

function generateSQToken { 
    echo "Waiting for jenkins connection on jenkins:8080"
    until timeout 1 bash -c "cat < /dev/null > /dev/tcp/jenkins/8080"
    do
        echo "Waiting for jenkins connection..."
        # wait for 5 seconds before check again
        sleep 5
    done

token=$(curlAdmin -X POST -H "Content-Type: application/x-www-form-urlencoded" -d "name=jenkins"  "$BASE_URL/api/user_tokens/generate" | jq -r '.token' | xargs)
echo "Jenkins token generated $token"
COOKIEJAR="$(mktemp)"
CRUMB=$(curlAdmin --cookie-jar "$COOKIEJAR" "http://jenkins:8080/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,%22:%22,//crumb)")
curlAdmin -X POST --cookie "$COOKIEJAR" -H "$CRUMB" "http://jenkins:8080/credentials/store/system/domain/_/createCredentials" --data-urlencode 'json={"": "0","credentials": {"scope": "GLOBAL","id": "jenkins","description": "Automatically generated sonar token from windows","secret": "'"$token"'", "$class": "org.jenkinsci.plugins.plaincredentials.impl.StringCredentialsImpl"}}'

}

# Check if the database is ready for connections
function waitForDatabase {
    # get HOST:PORT from JDBC URL
    if [[ $SONARQUBE_JDBC_URL =~ postgresql://([^:/]+)(:([0-9]+))?/ ]]; then
        local host=${BASH_REMATCH[1]}
        local port=${BASH_REMATCH[3]:-5432}
    else
        echo "Only PostgreSQL databases are supported"
        return
    fi
    echo "Waiting for database connection on $host:$port"
    until timeout 1 bash -c "cat < /dev/null > /dev/tcp/$host/$port"
    do
        echo "Waiting for database connection..."
        # wait for 5 seconds before check again
        sleep 5
    done
    echo "Database listening on ${HOSTPORT}"
}

# Wait until SonarQube is operational
function waitForSonarUp {
    # Wait for server to be up
    while [ "$status" != "UP" ]
    do
        status=$(curl -s -f "$BASE_URL/api/system/status" | jq -r '.status')
        echo "Waiting for sonar to come up: $status"
        sleep 5
    done
}

# Try to change the default admin password to the one provided in SONARQUBE_PASSWORD
function changeDefaultAdminPassword {
    if [ -n "$SONARQUBE_PASSWORD" ]; then 
        echo "Trying to change the default admin password"
        curl -s -X POST -u "admin:admin" -f "$BASE_URL/api/users/change_password?login=admin&password=${SONARQUBE_PASSWORD}&previousPassword=admin"
    fi
}

# Test admin credentials
function testAdminCredentials {
    authenticated=$(curl -s -u "$BASIC_AUTH" -f "$BASE_URL/api/system/info")
    if [ -z "$authenticated" ]; then
        echo "################################################################################"
        echo "No or incorrect admin credentials provided. Shutting down Sonarqube..."
        echo "################################################################################"
        exit 1
    fi
}

# given a profile name, retrieve its key
function getProfileKey {
    local searchProfileName=$1
    local searchLanguage=$2
    local getProfileKeyUrl="$BASE_URL/api/qualityprofiles/search?qualityProfile=$searchProfileName&language=$searchLanguage"
    local json=$(curl -u "$BASIC_AUTH" "$getProfileKeyUrl")
    local searchResultProfileKey=$(echo "$json" | grep -Eo '"key":"([_A-Z0-9a-z-]*)"' | cut -d: -f2 | sed -r 's/"//g')
    echo "$searchResultProfileKey"
}

function processRule {
    local rule=$1
    local profileKey=$2

    # The first character is the operation
    # + = activate
    # - = deactivate
    local operationType=${rule:0:1}

    # After the operation comes the SonarQube ruleSet which contains ruleId and ruleParams
    local ruleSet=${rule:1}
    IFS='|' read -r ruleId ruleParams <<< "$ruleSet"
    ruleParams=${ruleParams/|/,}

    echo "*** Processing rule ***"
    echo "Rule ${rule}"
    echo "Operation ${operationType}"
    echo "RuleId ${ruleId}"
    echo "RuleParams ${ruleParams}"

    if [ "$operationType" == "+" ]; then
        echo "Activating rule ${ruleId}"
        if [ "$ruleParams" == "" ]; then
            curlAdmin -X POST "$BASE_URL/api/qualityprofiles/activate_rule?key=$profileKey&rule=$ruleId"
        else
            curlAdmin -X POST "$BASE_URL/api/qualityprofiles/activate_rule?key=$profileKey&rule=$ruleId&params=$ruleParams"
        fi
    fi

    if [ "$operationType" == "-" ]; then
        echo "Deactivating rule ${ruleId}"
        curlAdmin -X POST "$BASE_URL/api/qualityprofiles/deactivate_rule?key=$profileKey&rule=$ruleId"
    fi
}

# Create a new SonarQube profile with custom activated rules, inheritance and set as default
# parameters
# $1 = profile name (the filename must match the profile name)
# $2 = parent profile name
# $3 = language (cs | java | py | js | ts | web | ...)
# $4 = comma separated list of rules (keys) to be activated in the profile (apart from the standard parent profile rules)
function createProfile {
    local profileName=$1
    local baseProfileName=$2
    local language=$3
    local rulesFilename="/tmp/rules/${language}.txt"

    # create profile
    # curlAdmin -X POST "$BASE_URL/api/qualityprofiles/create?name=$profileName&language=$language"
    # curlAdmin -X POST --data "qualityProfile=$1&parentQualityProfile=$2&language=$3" "$BASE_URL/api/qualityprofiles/change_parent"
    echo "Copying the profile $baseProfileName $language to $profileName"
    baseProfileKey=$(getProfileKey "$baseProfileName" "$language")
    copyProfileUrl="$BASE_URL/api/qualityprofiles/copy?toName=$profileName&fromKey=$baseProfileKey"
    echo "Posting to $copyProfileUrl"
    curlAdmin -X POST "$copyProfileUrl"

    profileKey=$(getProfileKey "$profileName" "$language")
    echo "The profile $profileName $language has the key $profileKey"

    # activate and deactivate rules in new profile
    while read ruleLine || [ -n "$line" ]; do

        # Each line contains a line with (+|-)ruleId # comment
        # Example: +cs:1032 # somecomment
        IFS='#';ruleSplit=("${ruleLine}");unset IFS;
        rule=${ruleSplit[0]}
        comment=${ruleSplit[1]}

        processRule "$rule" "$profileKey"

    done < "$rulesFilename"

    # if the PROJECT_RULES environment variable is defined and not empty, create a custom project profile
    echo "Project specific rules = $PROJECT_RULES"
    if [[ -n "$PROJECT_RULES" ]]; then
        echo "Creating custom project profile"

        local projectProfileName=$PROJECT_CODE-$profileName
        echo "Project custom profile name is $projectProfileName"

        # create project specific profile
        # curlAdmin -X POST "$BASE_URL/api/qualityprofiles/create?name=$projectProfileName&language=$language"
        # curlAdmin -X POST --data "qualityProfile=$projectProfileName&parentQualityProfile=$profileName&language=$3" "$BASE_URL/api/qualityprofiles/change_parent"
        echo "Copying the profile $baseProfileName $language to $profileName"
        curlAdmin -X POST "$BASE_URL/api/qualityprofiles/copy?fromKey=$profileKey&toName=$projectProfileName"

        # retrieve the new profile key
        profileKey=$(getProfileKey "$projectProfileName" "$language")
        echo "The profile $projectProfileName $language has the key $profileKey"

        IFS=';' read -ra projrules <<< "$PROJECT_RULES"
        for rule in "${projrules[@]}"; do
            echo "Processing project custom rule $rule"
            processRule "$rule" "$profileKey"
        done

        # mark this profile to be activated
        profileName=$projectProfileName
    fi

    # get current default profile name
    currentProfileName=$(curl -u "$BASIC_AUTH" -s "$BASE_URL/api/qualityprofiles/search?defaults=true" | jq -r --arg LANGUAGE "$3" '.profiles[] | select(.language==$LANGUAGE) | .name')
    echo "Current profile for language $3 is $currentProfileName"
    # set profile as default only when name does not end in DEFAULT or default
    shopt -s nocasematch
    if [[ $currentProfileName =~ .*DEFAULT$ ]]; then
        echo "Keeping current default profile $currentProfileName for language $3"
    else
        if [[ $currentProfileName =~ .*EXTENDED$ ]]; then
            echo "Changing parent of extended profile $currentProfileName for language $3 to $profileName"
            curlAdmin -X POST "$BASE_URL/api/qualityprofiles/change_parent?qualityProfile=$currentProfileName&parentQualityProfile=$profileName&language=$3"
        else 
            echo "Setting profile $profileName for language $3 as default"
            curlAdmin -X POST "$BASE_URL/api/qualityprofiles/set_default?qualityProfile=$profileName&language=$3"
        fi
    fi
}

###########################################################################################################################
# Main
###########################################################################################################################
BASE_URL=http://sonarqube:9000


# waitForDatabase
if [ "$SONARQUBE_JDBC_URL" ]; then
  waitForDatabase
fi

# add shutdown hook
function shutdown {
    echo "Shutdown"
    if [[ -n $PID ]]; then
        kill $PID
        wait $PID
    fi
}
trap "shutdown" EXIT

# Start Sonar
./bin/run.sh &
PID=$!

waitForSonarUp

changeDefaultAdminPassword

testAdminCredentials

createJenkinsWebhook
generateSQToken


# (Re-)create the profiles

createProfile "cs-profile-v8.18.0" "Sonar%20way" "cs"
createProfile "py-profile-v3.2.0" "Sonar%20way" "py"

wait $PID
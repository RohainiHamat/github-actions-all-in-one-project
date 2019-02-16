#!/bin/sh -eux

echo "$@"
env | sort
jq < "$GITHUB_EVENT_PATH"

CONTENT_TYPE="$1"
ACTION=$(jq -r '.action' < "$GITHUB_EVENT_PATH")

if [ "$ACTION" != opened ]; then
  echo "This action was ignored. (ACTION: $ACTION)"
  exit 0
fi

get_project_type() {
  _PROJECT_URL="$1"

  case "$_PROJECT_URL" in
    https://github.com/orgs/*)
      echo "org"
      ;;
    https://github.com/users/*)
      echo "user"
      ;;
    https://github.com/*/projects/*)
      echo "repo"
      ;;
    *)
      echo "Invalid PROJECT_URL: $_PROJECT_URL" >&2
      false
      ;;
  esac

  unset _PROJECT_URL
}

find_project_id() {
  _PROJECT_TYPE="$1"
  _PROJECT_URL="$2"

  case "$_PROJECT_TYPE" in
    org)
      _ORG_NAME=$(echo "$_PROJECT_URL" | sed -e 's@https://github.com/orgs/\([^/]\+\)/projects/[0-9]\+@\1@')
      _ENDPOINT="https://api.github.com/orgs/$_ORG_NAME/projects"
      ;;
    user)
      _USER_NAME=$(echo "$_PROJECT_URL" | sed -e 's@https://github.com/users/\([^/]\+\)/projects/[0-9]\+@\1@')
      _ENDPOINT="https://api.github.com/users/$_USER_NAME/projects"
      ;;
    repo)
      _ENDPOINT="https://api.github.com/repos/$GITHUB_REPOSITORY/projects"
      ;;
  esac

  _PROJECTS=$(curl -s -X GET -u "$GITHUB_ACTOR:$TOKEN" --retry 3 \
		   -H 'Accept: application/vnd.github.inertia-preview+json' \
		   "$_ENDPOINT")

  if [ "$(echo "$_PROJECTS" | jq '. | length == 0')" = true ]; then
    echo "No project was found." >&2
    false
  fi

  echo "$_PROJECTS" | jq -r ".[] | select(.html_url == \"$_PROJECT_URL\").id"
  unset _PROJECT_TYPE _PROJECT_URL _ORG_NAME _USER_NAME _ENDPOINT _PROJECTS
}

find_column_id() {
  _PROJECT_ID="$1"
  _INITIAL_COLUMN_NAME="$2"
  _COLUMNS=$(curl -s -X GET -u "$GITHUB_ACTOR:$TOKEN" --retry 3 \
		  -H 'Accept: application/vnd.github.inertia-preview+json' \
		  "https://api.github.com/projects/$_PROJECT_ID/columns")
  echo "$_COLUMNS" | jq -r ".[] | select(.name == \"$_INITIAL_COLUMN_NAME\").id"
  unset _PROJECT_ID _INITIAL_COLUMN_NAME _COLUMNS
}

PROJECT_TYPE=$(get_project_type "${PROJECT_URL:?<Error> required this environment variable}")

if [ "$PROJECT_TYPE" = org ] || [ "$PROJECT_TYPE" = user ]; then
  TOKEN="$MY_GITHUB_TOKEN" # It's User's personal access token. It should be secret.
else
  TOKEN="$GITHUB_TOKEN"    # GitHub sets. The scope in only the repository containing the workflow file.
fi

PROJECT_ID=$(find_project_id "$PROJECT_TYPE" "$PROJECT_URL")
INITIAL_COLUMN_ID=$(find_column_id "$PROJECT_ID" "${INITIAL_COLUMN_NAME:?<Error> required this environment variable}")

if [ -z "$INITIAL_COLUMN_ID" ]; then
  echo "INITIAL_COLUMN_ID is not found." >&2
  exit 1
fi

case "$CONTENT_TYPE" in
  issue)
    ISSUE_ID=$(jq -r '.issue.id' < "$GITHUB_EVENT_PATH")

    # Add this issue to the project column
    curl -s -X POST -u "$GITHUB_ACTOR:$TOKEN" --retry 3 \
	 -H 'Accept: application/vnd.github.inertia-preview+json' \
	 -d "{\"content_type\": \"Issue\", \"content_id\": $ISSUE_ID}" \
	 "https://api.github.com/projects/columns/$INITIAL_COLUMN_ID/cards"
    ;;
  pull_request)
    PULL_REQUEST_ID=$(jq -r '.pull_request.id' < "$GITHUB_EVENT_PATH")

    # Add this pull_request to the project column
    curl -s -X POST -u "$GITHUB_ACTOR:$TOKEN" --retry 3 \
	 -H 'Accept: application/vnd.github.inertia-preview+json' \
	 -d "{\"content_type\": \"PullRequest\", \"content_id\": $PULL_REQUEST_ID}" \
	 "https://api.github.com/projects/columns/$INITIAL_COLUMN_ID/cards"
    ;;
  *)
    echo "Invalid arg $CONTENT_TYPE" >&2
    exit 1
    ;;
esac

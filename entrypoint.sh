#!/bin/bash

set -eo pipefail

shopt -s extglob  # Enable extended globbing

# config
default_semvar_bump=${DEFAULT_BUMP:-minor}
default_branch=${DEFAULT_BRANCH:-$GITHUB_BASE_REF} # get the default branch from github runner env vars
with_v=${WITH_V:-false}
release_branches=${RELEASE_BRANCHES:-master,main}
custom_tag=${CUSTOM_TAG:-}
source=${SOURCE:-.}
dryrun=${DRY_RUN:-false}
git_api_tagging=${GIT_API_TAGGING:-true}
initial_version=${INITIAL_VERSION:-0.0.0}
tag_context=${TAG_CONTEXT:-repo}
tag_prefix=${TAG_PREFIX:-false}
prerelease=${PRERELEASE:-false}
suffix=${PRERELEASE_SUFFIX:-beta}
verbose=${VERBOSE:-false}
major_string_token=${MAJOR_STRING_TOKEN:-#major}
minor_string_token=${MINOR_STRING_TOKEN:-#minor}
patch_string_token=${PATCH_STRING_TOKEN:-#patch}
none_string_token=${NONE_STRING_TOKEN:-#none}
branch_history=${BRANCH_HISTORY:-compare}
force_without_changes=${FORCE_WITHOUT_CHANGES:-false}
force_without_changes_pre=${FORCE_WITHOUT_CHANGES:-false}
tag_message=${TAG_MESSAGE:-""}

# since https://github.blog/2022-04-12-git-security-vulnerability-announced/ runner uses?
git config --global --add safe.directory /github/workspace

cd "${GITHUB_WORKSPACE}/${source}" || exit 1

echo "*** CONFIGURATION ***"
echo -e "\tDEFAULT_BUMP: ${default_semvar_bump}"
echo -e "\tDEFAULT_BRANCH: ${default_branch}"
echo -e "\tWITH_V: ${with_v}"
echo -e "\tRELEASE_BRANCHES: ${release_branches}"
echo -e "\tCUSTOM_TAG: ${custom_tag}"
echo -e "\tSOURCE: ${source}"
echo -e "\tDRY_RUN: ${dryrun}"
echo -e "\tGIT_API_TAGGING: ${git_api_tagging}"
echo -e "\tINITIAL_VERSION: ${initial_version}"
echo -e "\tTAG_CONTEXT: ${tag_context}"
echo -e "\tTAG_PREFIX: ${tag_prefix}"
echo -e "\tPRERELEASE: ${prerelease}"
echo -e "\tPRERELEASE_SUFFIX: ${suffix}"
echo -e "\tVERBOSE: ${verbose}"
echo -e "\tMAJOR_STRING_TOKEN: ${major_string_token}"
echo -e "\tMINOR_STRING_TOKEN: ${minor_string_token}"
echo -e "\tPATCH_STRING_TOKEN: ${patch_string_token}"
echo -e "\tNONE_STRING_TOKEN: ${none_string_token}"
echo -e "\tBRANCH_HISTORY: ${branch_history}"
echo -e "\tFORCE_WITHOUT_CHANGES: ${force_without_changes}"
echo -e "\tFORCE_WITHOUT_CHANGES_PRE: ${force_without_changes_pre}"
echo -e "\tTAG_MESSAGE: ${tag_message}"

# verbose, show everything
if $verbose
then
    set -x
fi

setOutput() {
    echo "${1}=${2}" >> "${GITHUB_OUTPUT}"
}

current_branch=$(git rev-parse --abbrev-ref HEAD)

pre_release="$prerelease"
IFS=',' read -ra branch <<< "$release_branches"
for b in "${branch[@]}"; do
    # check if ${current_branch} is in ${release_branches} | exact branch match
    if [[ "$current_branch" == "$b" ]]
    then
        pre_release="false"
    fi
    # verify non specific branch names like  .* release/* if wildcard filter then =~
    if [ "$b" != "${b//[\[\]|.? +*]/}" ] && [[ "$current_branch" =~ $b ]]
    then
        pre_release="false"
    fi
done
echo "pre_release = $pre_release"

# fetch tags
git fetch --tags

# Set no tag prefix (not even v)
tagPrefix=""

if $with_v
then
    tagPrefix="v"
fi

# If a tag_prefix is supplied use that
if [[ "${tag_prefix}" != "false" ]]
then
  tagPrefix=$tag_prefix
fi

tagFmt="^$tagPrefix?[0-9]+\.[0-9]+\.[0-9]+$"
preTagFmt="^$tagPrefix?[0-9]+\.[0-9]+\.[0-9]+(-$suffix\.[0-9]+)$"

# get the git refs
git_refs=
case "$tag_context" in
    *repo*)
        git_refs=$(git for-each-ref --sort=-v:refname --format '%(refname:lstrip=2)')
        ;;
    *branch*)
        git_refs=$(git tag --list --merged HEAD --sort=-committerdate)
        ;;
    * ) echo "Unrecognised context"
        exit 1;;
esac

# get the latest tag that looks like a semver (with or without v)
matching_tag_refs=$( (grep -E "$tagFmt" <<< "$git_refs") || true)
matching_pre_tag_refs=$( (grep -E "$preTagFmt" <<< "$git_refs") || true)
tag=$(head -n 1 <<< "$matching_tag_refs")
pre_tag=$(head -n 1 <<< "$matching_pre_tag_refs")

# Initialise old tag values
old_tag=$tag
old_pre_tag=$pre_tag

# if there are none, start tags at initial version
if [ -z "$tag" ]
then
    tag="$tagPrefix$initial_version"
    if [ -z "$pre_tag" ] && $pre_release
    then
        pre_tag="$tagPrefix$initial_version"
    fi
fi

# get current commit hash for tag
tag_commit=$(git rev-list -n 1 "$tag" || true )
# get current commit hash
commit=$(git rev-parse HEAD)
# skip if there are no new commits for non-pre_release
if [ "$tag_commit" == "$commit" ] && [ "$force_without_changes" == "false" ]
then
    echo "No new commits since previous tag. Skipping..."
    setOutput "new_tag" "$tag"
    setOutput "tag" "$tag"
    setOutput "old_tag" "$old_tag"
    exit 0
fi

# sanitize that the default_branch is set (via env var when running on PRs) else find it natively
if [ -z "${default_branch}" ] && [ "$branch_history" == "full" ]
then
    echo "The DEFAULT_BRANCH should be autodetected when tag-action runs on on PRs else must be defined, See: https://github.com/anothrNick/github-tag-action/pull/230, since is not defined we find it natively"
    default_branch=$(git branch -rl '*/master' '*/main' | cut -d / -f2)
    echo "default_branch=${default_branch}"
    # re check this
    if [ -z "${default_branch}" ]
    then
        echo "::error::DEFAULT_BRANCH must not be null, something has gone wrong."
        exit 1
    fi
fi

# get the merge commit message looking for #bumps
declare -A history_type=(
    ["last"]="$(git show -s --format=%B)" \
    ["full"]="$(git log "${default_branch}"..HEAD --format=%B)" \
    ["compare"]="$(git log "${tag_commit}".."${commit}" --format=%B)" \
)
log=${history_type[${branch_history}]}
printf "History:\n---\n%s\n---\n" "$log"

if [ -z "$tagPrefix" ]
then
  current_tag=${tag}
else
  current_tag="$(echo ${tag}| sed "s/${tagPrefix}//g")"
fi

handleNoDefaultBump() {
    echo "Default bump was set to none. Skipping..."
    setOutput "new_tag" "$tag"
    setOutput "tag" "$tag"
    setOutput "part" "$default_semvar_bump"

    # Check that the prelease tag is equal to or greater than the base tag, ignoring the prerelease suffix
    # We don't want to set the old tag to pre_tag if the found pre_tag is from a lower semver version.
    if [[ -n $(semver "${pre_tag#"$tagPrefix"}" --range ">=$current_tag" -n 0 --preid prerelease --include-prerelease) ]]; then
        setOutput "old_tag" "$old_pre_tag"
    else
        setOutput "old_tag" "$old_tag"
    fi
            
    exit 0
}

case "$log" in
    *$major_string_token* ) new=${tagPrefix}$(semver -i major "${current_tag}"); part="major";;
    *$minor_string_token* ) new=${tagPrefix}$(semver -i minor "${current_tag}"); part="minor";;
    *$patch_string_token* ) new=${tagPrefix}$(semver -i patch "${current_tag}"); part="patch";;
    *$none_string_token* )
        handleNoDefaultBump;;
    * )
        if [ "$default_semvar_bump" == "none" ]
        then
            handleNoDefaultBump
        else
            new=${tagPrefix}$(semver -i "${default_semvar_bump}" "${current_tag}")
            part=$default_semvar_bump
        fi
        ;;
esac

if $pre_release
then
    # get current commit hash for tag
    pre_tag_commit=$(git rev-list -n 1 "$pre_tag" || true)
    # skip if there are no new commits for pre_release
    if [ "$pre_tag_commit" == "$commit" ] &&  [ "$force_without_changes_pre" == "false" ]
    then
        echo "No new commits since previous pre_tag. Skipping..."
        setOutput "new_tag" "$pre_tag"
        setOutput "tag" "$pre_tag"
        setOutput "old_tag" "$old_pre_tag"
        exit 0
    fi
    # already a pre-release available, bump it
    if [[ "$pre_tag" =~ $new ]] && [[ "$pre_tag" =~ $suffix ]]
    then
        new=${tagPrefix}$(semver -i prerelease "${pre_tag#"$tagPrefix"}" --preid "${suffix}")
        echo -e "Bumping ${suffix} pre-tag ${pre_tag}. New pre-tag ${new}"
        setOutput "old_tag" "$old_pre_tag"
    else
        new="${new}-${suffix}.0"
        echo -e "Setting ${suffix} pre-tag ${pre_tag} - With pre-tag ${new}"
        setOutput "old_tag" "$old_tag"
    fi
    part="pre-$part"
else
    echo -e "Bumping tag ${tag} - New tag ${new}"
    setOutput "old_tag" "$old_tag"
fi

# as defined in readme if CUSTOM_TAG is used any semver calculations are irrelevant.
if [ -n "$custom_tag" ]
then
    new="$custom_tag"
fi

# set outputs
setOutput "new_tag" "$new"
setOutput "part" "$part"
setOutput "tag" "$new" # this needs to go in v2 is breaking change

# dry run exit without real changes
if $dryrun
then
    exit 0
fi

# Modify the tag creation part
if [ -n "$tag_message" ]
then
    echo "EVENT: creating local tag $new with message: $tag_message"
    git tag -a "$new" -m "$tag_message" || exit 1
else
    echo "EVENT: creating local tag $new"
    git tag -f "$new" || exit 1
fi

echo "EVENT: pushing tag $new to origin"

if $git_api_tagging
then
    # use git api to push
    dt=$(date '+%Y-%m-%dT%H:%M:%SZ')
    full_name=$GITHUB_REPOSITORY
    git_refs_url=$(jq .repository.git_refs_url "$GITHUB_EVENT_PATH" | tr -d '"' | sed 's/{\/sha}//g')

    echo "$dt: **pushing tag $new to repo $full_name"

    git_refs_response=$(
    curl -s -X POST "$git_refs_url" \
    -H "Authorization: token $GITHUB_TOKEN" \
    -d @- << EOF
{
    "ref": "refs/tags/$new",
    "sha": "$commit"
}
EOF
)

    git_ref_posted=$( echo "${git_refs_response}" | jq .ref | tr -d '"' )

    echo "::debug::${git_refs_response}"
    if [ "${git_ref_posted}" = "refs/tags/${new}" ]
    then
        exit 0
    else
        echo "::error::Tag was not created properly."
        exit 1
    fi
else
    # use git cli to push
    git push -f origin "$new" || exit 1
fi

#!/usr/bin/env bash

set -e

ELPAURL="http://marmalade-repo.org/"
UPLOADURL="https://github.com/jorgenschaefer/circe/downloads"

if [ ! -f "lisp/circe.el" ]
then
    echo "Please call this from the Circe main directory" >&2
    exit 1
fi


main () {
    if [ "$1" = "release" ]
    then
        do_release
    elif [ "$1" = "build" ] || [ "$1" = "" ]
    then
        do_build
    fi
}

do_build () {
    rm -rf build/
    mkdir -p build/
    cp lisp/*.el build/
    elisp_autoloads circe "$(pwd)/build/"
    elisp_compile "$(pwd)/build/"
    echo
    echo "Compiled files can be found in build/"
}

do_release () {
    if git_repository_dirty
    then
        echo "This repository is dirty. Please clean up for a release."
        exit 1
    fi

    rm -rf release

    declare -a GIT_TAG_COMMANDS
    declare -A VERSION_DICT

    LAST_LCS="$(git_last_tag "lcs-*")"
    VERSION_DICT[lcs]="${LAST_LCS#*-}"
    if git_files_changed "$LAST_LCS" "^lisp/lcs.el"
    then
        mkdir -p release
        echo -n "Building lcs ... "
        elpa_file lcs lisp/lcs.el "$LAST_LCS"
        echo "ok."
    fi

    LAST_SHORTEN="$(git_last_tag "shorten-*")"
    VERSION_DICT[shorten]="${LAST_SHORTEN#*-}"
    if git_files_changed "$LAST_SHORTEN" "^lisp/shorten.el"
    then
        mkdir -p release
        echo -n "Building shorten ... "
        elpa_file shorten lisp/shorten.el "$LAST_SHORTEN"
        echo "ok."
    fi

    LAST_TRACKING="$(git_last_tag "tracking-*")"
    VERSION_DICT[tracking]="${LAST_TRACKING#*-}"
    if git_files_changed "$LAST_TRACKING" "^lisp/tracking.el"
    then
        mkdir -p release
        echo -n "Building tracking ... "
        elpa_file tracking lisp/tracking.el "$LAST_TRACKING"
        echo "ok."
    fi

    LAST_LUI="$(git_last_tag "lui-*")"
    VERSION_DICT[lui]="${LAST_LUI#*-}"
    if git_files_changed "$LAST_LUI" "^lisp/lui"
    then
        mkdir -p release
        echo -n "Building Lui ... "
        elpa_tar lui lisp/lui.el "$LAST_LUI"
        echo "ok."
    fi

    LAST_CIRCE="$(git_last_tag "circe-*")"
    VERSION_DICT[circe]="${LAST_CIRCE#*-}"
    if git_files_changed "$LAST_CIRCE" "^lisp/circe"
    then
        mkdir -p release
        echo -n "Building Circe ... "
        elpa_tar circe lisp/circe.el "$LAST_CIRCE"
        echo "ok."
    fi

    if [ ! -d release ]
    then
        echo "Nothing changed since last release."
    else
        echo
        echo "Release fully prepared. Run these commands:"
        echo
        for cmd in "${GIT_TAG_COMMANDS[@]}"
        do
            echo "$cmd"
        done
        echo
        echo "git push --tags"
        echo
        for name in release/*.tar release/*.el
        do
            if [ -f "$name" ]
            then
                echo "- Upload $name to $ELPAURL"
            fi
        done
    fi
}

##################################################################
# Git functions

git_files_changed () {
    local START="$1"
    local PATTERN="$2"
    git diff --name-only "$START" | grep -q "$PATTERN"
}

git_repository_dirty () {
    if git diff-index HEAD --quiet --
    then
        return 1
    else
        return 0
    fi
}

git_last_tag () {
    git describe --tags --abbrev=0 --match="$1" HEAD
}

##################################################################
# Elisp related functions

elisp_autoloads () {
    local PACKAGE="$1"
    local DEST="$2"
    local AUTOLOAD="$DEST/$PACKAGE-autoloads.el"
    emacs -q --batch --eval \
      "(let ((generated-autoload-file \"$AUTOLOAD\"))
         (batch-update-autoloads))" \
      "$DEST"
    rm "$DEST"/*.el~
}

elisp_compile () {
    local DEST="$1"
    emacs -q --batch --eval "(add-to-list 'load-path \"$DEST\")" \
          -f batch-byte-compile "$DEST"/*.el
}

elisp_version () {
    sed -ne 's/^;; *Version: \([0-9.]*\).*/\1/p' "$1"
}

elisp_defvar_version () {
    sed -ne 's/(defvar [^ ]*-version "\(.*\)"/\1/p' "$1"
}

# This is more complex than it should be, but files in lisp/ used to
# be in the main directory.
elisp_version_in () {
    local REV="$1"
    local FILE="$2"

    (git show "$REV:$FILE" 2>/dev/null \
     || git show "$REV:${FILE#lisp/}"
    ) | sed -ne 's/^;; *Version: \([0-9.]*\).*/\1/p'
}

elisp_short_description () {
    sed -ne '1s/.*--- //p' "$1"
}

##################################################################
# Elpa helper functions

elpa_readme () {
    local LISPFILE="$1"
    local README="$2"
    cat "$LISPFILE" \
    | sed -e '1,/^;;;.*Commentary:.*/d' \
          -e '/^;;; Code:/,$d' \
    | sed -e '1d' -e '$d' \
          -e 's/^;* *//' \
    > "$README"
}


elpa_pkg_file () {
    local PKGFILE="$1" # build/circe-0.1/circe-pkg.el
    local PACKAGE="$2" # circe
    local VERSION="$3" # 1.0

    VERSION_DICT["$PACKAGE"]="$VERSION"
    (
        echo ",s/\\\$VERSION/$VERSION/g"
        for pkgname in "${!VERSION_DICT[@]}"
        do
            echo ",s/($pkgname \"[0-9.]\\+\")/($pkgname \"${VERSION_DICT[$pkgname]}\")/g"
        done
        echo "w"
    ) | ed "$PKGFILE" 2>/dev/null || :
}

elpa_tar () {
    local PACKAGE="$1" # circe
    local FILENAME="$2" # lisp/circe.el
    local OLD_TAG="$3" # circe-0.5

    local OLD_VERSION="$(elisp_version_in "$OLD_TAG" "$FILENAME")"
    local VERSION="$(elisp_version "$FILENAME")"
    local TAG="$PACKAGE-$VERSION"
    local DEFVAR_VERSION="$(elisp_defvar_version "$FILENAME")"

    if [ -n "$DEFVAR_VERSION" ] && [ "$VERSION" != "$DEFVAR_VERSION" ]
    then
        echo "File and defvar version disagree, aborting."
        exit 1
    fi
    if [ "$VERSION" = "$OLD_VERSION" ]
    then
        echo "File version $VERSION has not changed, aborting."
        exit 1
    fi
    if [ "$TAG" = "$OLD_TAG" ]
    then
        echo "Tag $TAG is the same as the old tag, aborting."
        exit 1
    fi

    GIT_TAG_COMMANDS+=("git tag -a -m \"Released $TAG\" \"$TAG\" HEAD")

    local DEST="$(pwd)/release/$PACKAGE-$VERSION/"
    mkdir -p "$DEST"
    cp -r LICENSE "lisp/$PACKAGE"* "$DEST"
    local DESC="$(elisp_short_description lisp/$PACKAGE.el)"
    elpa_readme "$DEST/$PACKAGE.el" "$DEST/README"
    elisp_autoloads "$PACKAGE" "$DEST" 2>/dev/null
    mv "$DEST/$PACKAGE-pkg.el.in" "$DEST/$PACKAGE-pkg.el"
    elpa_pkg_file "$DEST/$PACKAGE-pkg.el" "$PACKAGE" "$VERSION"
    tar -C release/ -c "$PACKAGE-$VERSION" \
    > "release/$PACKAGE-$VERSION.tar"
    rm -rf "$DEST"
}

elpa_file () {
    local PROJECT="$1"
    local FILENAME="$2"
    local OLD_TAG="$3"

    local OLD_VERSION="$(elisp_version_in "$OLD_TAG" "$FILENAME")"
    local VERSION="$(elisp_version "$FILENAME")"
    local TAG="$PROJECT-$VERSION"
    local DEFVAR_VERSION="$(elisp_defvar_version "$FILENAME")"

    VERSION_DICT["$PROJECT"]="$VERSION"

    if [ -n "$DEFVAR_VERSION" ] && [ "$VERSION" != "$DEFVAR_VERSION" ]
    then
        echo "File version and defvar version disagree, aborting."
        exit 1
    fi
    if [ "$VERSION" = "$OLD_VERSION" ]
    then
        echo "File version $VERSION has not changed, aborting."
        exit 1
    fi
    if [ "$TAG" = "$OLD_TAG" ]
    then
        echo "Tag $TAG is the same as the old tag, aborting."
        exit 1
    fi

    GIT_TAG_COMMANDS+=("git tag -a -m \"Released $TAG\" \"$TAG\" HEAD")

    cp "$FILENAME" release/
    elpa_file_adjust_versions release/"$(basename "$FILENAME")"
}


elpa_file_adjust_versions () {
    local FILENAME="$1"
    # Adjust ;; Requirements: ((shorten "[0-9.]*")) with correct
    # versions from VERSION_DICT

    (
        for pkgname in "${!VERSION_DICT[@]}"
        do
            echo "/^;; Package-Requires:/s/($pkgname \"[0-9.]\\+\")/($pkgname \"${VERSION_DICT[$pkgname]}\")/g"
        done
        echo "w"
    ) | ed "$FILENAME" 2> /dev/null || :
}

main "$@"

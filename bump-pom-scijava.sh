#!/bin/sh

die () {
	echo "$*" >&2
	exit 1
}

skip_commit=
bump_parent=
while test $# -gt 0
do
	case "$1" in
	--skip-commit)
		skip_commit=t
		;;
	--bump-parent)
		bump_parent=t
		;;
	--default-properties)
		# handle later
		break
		;;
	-*)
		die "Unknown option: $1"
		;;
	*)
		break
		;;
	esac
	shift
done

require_clean_worktree () {
	test -z "$skip_commit" ||
	return

	git rev-parse HEAD@{u} > /dev/null 2>&1 ||
	die "No upstream configured for the current branch"

	git update-index -q --refresh &&
	git diff-files --quiet --ignore-submodules &&
	git diff-index --cached --quiet --ignore-submodules HEAD -- ||
	die "There are uncommitted changes!"
}

commit () {
	test -n "$skip_commit" || {
		git commit -s -m "$@" ||
		die "Could not commit"
	}
}

maven_helper="$(cd "$(dirname "$0")" && pwd)/maven-helper.sh" &&
test -f "$maven_helper" ||
die "Could not find maven-helper.sh"

test -z "$bump_parent" || {
	require_clean_worktree

	test -f pom.xml ||
	die "Not found: pom.xml"

	gav="$(sh "$maven_helper" gav-from-pom pom.xml)" ||
	die "Could not extract GAV from pom.xml"

	case "$gav" in
	*-SNAPSHOT)
		;;
	*)
		die "Not a -SNAPSHOT version: $gav"
		;;
	esac

	gav="$(sh "$maven_helper" parent-gav-from-pom pom.xml)" &&
	version="${gav#org.scijava:pom-scijava:}" &&
	test "$version" != "$gav" ||
	die "Parent is not pom-scijava: $gav"

	latest="$(sh "$maven_helper" latest-version org.scijava:pom-scijava)" &&
	test -n "$latest" ||
	die "Could not determine latest pom-scijava version"

	test $version != $latest || {
		echo "Parent is already the newest pom-scijava version: $version" >&2
		exit 0
	}

	sed "/<parent>/,/<\/parent>/s/\(<version>\)$version\(<\/version>\)/\1$latest\2/" \
		pom.xml > pom.xml.new &&
	mv -f pom.xml.new pom.xml ||
	die "Could not edit pom.xml"

	commit "Bump parent to $latest" pom.xml

	exit
}

test "a--default-properties" != "a$*" ||
set $(sed -n '/^	<properties>/,/<!-- Open Microscopy Environment/s/.*<\([^>\/]*\.version\)>.*/\1 --latest/p' pom.xml)

test $# -ge 2 &&
test 0 = $(($#%2)) ||
die "Usage: $0 [--skip-commit] (--bump-parent | --default-properties | <key> <value>...)"

pom=pom.xml
cd "$(dirname "$0")/../pom-scijava" &&
test -f $pom ||
die "Could not switch to pom-scijava's root directory"

require_clean_worktree

sed_quote () {
	echo "$1" | sed "s/[]\/\"\'\\\\(){}[\!\$  ;]/\\\\&/g"
}

gav="$(sh "$maven_helper" gav-from-pom $pom)"
old_version=${gav##*:}
new_version="${old_version%-SNAPSHOT}"
test "$old_version" != "$new_version" ||
new_version=${old_version%.*}.$((1 + ${old_version##*.}))-SNAPSHOT

message="$(printf "%s\n" "The following changes were made:")"
while test $# -ge 2
do
	must_change=t
	latest_message=
	property="$1"
	value="$2"
	if test "a--latest" = "a$value"
	then
		must_change=
		artifactId="${property%.version}"
		case "$artifactId" in
		scijava-maven-plugin)
			ga=org.scijava:$artifactId
			;;
		*)
			ga="$(sed -n '/<groupId>/{
N;
s/.*<groupId>\([^<]*\).*<artifactId>'"$artifactId"'<.*/\1/p
}' pom.xml | head -n 1):$artifactId"
			;;
		esac
		latest_message=" (latest $ga)"
		value="$(sh "$maven_helper" latest-version "$ga")"
	fi

	p="$(sed_quote "$property")"
	v="$(sed_quote "$value")"
	# Set the primary property version
	sed \
	 -e "/^	<properties>/,/^	<\/properties>/s/\(<$p>\)[^<]*\(<\/$p>\)/\1$v\2/" \
	  $pom > $pom.new &&
	if ! cmp $pom $pom.new
	then
		message="$(printf '%s\n\t%s = %s%s' \
			"$message" "$property" "$value" "$latest_message")"
	elif test -n "$must_change"
	then
		die "Property $property not found in $pom"
	fi &&
	mv $pom.new $pom ||
	die "Failed to set property $property = $value"

	# Set the profile snapshot version
	value="$(sh "$maven_helper" latest-version "$ga:SNAPSHOT")"
	v="$(sed_quote "$value")"
	sed -e "/<profiles>/,/<\/profiles>/s/\(<$p>\)[^<]*\(<\/$p>\)/\1$v\2/" \
	  $pom > $pom.new &&
	if ! cmp $pom $pom.new
	then
		message="$(printf '%s\n\t%s = %s%s' \
			"$message" "$property" "$value" "$latest_message")"
	elif test -n "$must_change"
	then
		die "Profile property $property not found in $pom"
	fi &&
	mv $pom.new $pom ||
	die "Failed to set profile property $property = $value"

	shift
	shift
done

! git diff --quiet $pom || {
	echo "No properties changed!" >&2
	# help detect when no commit is required by --default-properties
	exit 128
}

case "$old_version" in
*-SNAPSHOT) ;;
*)
	mv $pom $pom.new &&
	sed \
	  -e "s/^\(\\t<version>\)$old_version\(<\/version>\)/\1$new_version\2/" \
	  $pom.new > $pom &&
	! cmp $pom $pom.new ||
	die "Failed to increase version of $pom"

	rm $pom.new ||
	die "Failed to remove intermediate $pom.new"
	;;
esac

commit "Bump component versions" \
	-m "$message" $pom

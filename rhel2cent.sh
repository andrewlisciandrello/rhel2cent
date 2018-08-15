#!/bin/bash

# A DRY function to return the current filename for a specified package
# Takes 2 arguments
#   $1 - HTML response from the package dir listing
#   $2 - Regex to match package, left bound by a '>' that will be automatically added for you
function cur_file() {
	echo "$1" | grep ">$2" | sed -n 's/.*<a.*>\(.*\)<\/a>.*/\1/p'
}

# Are we root?
if [ "$EUID" != "0" ]; then
	echo "This script must be run with root level permissions."
	exit 1
fi

# Do we have the rpm command?
if [ -z `which rpm` ]; then
	echo "The rpm command was not found. Is this Red Hat?"
	exit 1
fi

# Is the redhat-release package here?
if [ `rpm -qa | grep -c ^redhat-release` -lt 1 ]; then
	echo "This OS does not appear to be Red Hat."
	exit 1
fi

# Do we want to yum upgrade at the end?
if [ $# == 1 ]; then
	UPGRADE=1
fi

# Some useful vars
STAMP=`date +"%Y%m%d"`
VER=`sed -n 's/[^0-9]*\([0-9]*\)\.[0-9]*.*/\1/p' /etc/redhat-release`
MINORVER=`sed -n 's/[^0-9]*[0-9]*\.\([0-9]*\).*/\1/p' /etc/redhat-release`
ARCH=`uname -i`
CURVER=`curl -s http://mirror.centos.org/centos/ | egrep -o "${VER}\.[0-9]+" | tail -1`
CURMINORVER=${CURVER//[0-9]*./}

# Set the package dir based on the major version, if the version is unexpected, then exit
if [ "$VER" == "6" ]; then
	PKGDIR="Packages"
elif [ "$VER" == "5" ]; then
	PKGDIR="CentOS"
else
	echo "This version of Red Hat (${VER}) is not supported."
	exit 1
fi

# Build the baseurl to retrieve the CentOS packages based on the
# current Red Hat version. Use vault, if we are behind on the version, so that
# the redhat-release package and other packages match the current version
# to prevent *having* to upgrade
if [ ${MINORVER} -gt ${CURMINORVER} ]; then
	echo "This version of RHEL (${VER}.${MINORVER}) is newer than the latest released version of CentOS (${CURVER})"
	exit 1
elif [ "${VER}.${MINORVER}" == "${CURVER}" ]; then
	BASEURL="http://mirror.centos.org/centos/${VER}/os/${ARCH}/${PKGDIR}"
else
	BASEURL="http://mirror.1000mbps.com/centos-vault/${VER}.${MINORVER}/os/${ARCH}/${PKGDIR}"
fi

# Back up supplemental repositories
echo "Backing up .repo files in /etc/yum.repos.d..."
for REPO in `ls -1 /etc/yum.repos.d/*.repo`; do
	mv $REPO $REPO.$STAMP.rhel2centos
	if [ $? -ne 0 ]; then
		echo "Could not move ${REPO} to ${REPO}.${STAMP}.rhel2centos, disabling automattic upgrade."
		unset UPGRADE
	fi
done

NOTFROMRH=`rpm -qa --qf '%{NAME} -- %{VENDOR}\n' | egrep -v 'Red Hat, Inc.|None$|none\)$' | sort -t" " -k3`
if [ -n "$NOTFROMRH" ]; then
	echo ""
	echo "The following packages were not installed from a Red Hat repository:"
	echo "${NOTFROMRH}"
	echo ""
fi

# Make a temp dir to store RPMs and Key
echo "Creating temporary package directory at /tmp/rhel2centos..."
mkdir -p /tmp/rhel2centos
if [ $? -ne 0 ]; then
	echo "Failed to create /tmp/rhel2centos."
	exit 1
fi
rm -fv /tmp/rhel2centos/*
cd /tmp/rhel2centos
if [ $? -ne 0 ]; then
	echo "Could not change directories to /tmp/rhel2centos"
	exit 1
fi

# Download the required RPMs and Key
echo "Downloading required RPMs and GPG key file..."
PKGLIST=`curl -s ${BASEURL}/`
if [ `echo "$PKGLIST" | grep -c 'Index of'` -eq 0 ]; then
	echo "Package listing could not be sucessfully retrieved."
	exit 1
fi

PKGS="centos-release-${VER} yum-[0-9] yum-utils-[0-9]"

if [ "$VER" == "5" ]; then
	PKGS="${PKGS} yum-fastestmirror centos-release-notes-${VER} yum-updatesd gamin-[0-9] gamin-python-[0-9] glib2-[0-9] pygobject2-[0-9]"
elif [ "$VER" == "6" ]; then
	PKGS="${PKGS} yum-plugin-fastestmirror"
fi

wget http://mirror.centos.org/centos/RPM-GPG-KEY-CentOS-${VER}
if [ $? -ne 0 ]; then
	echo "Retrieval of the CentOS GPG package signing key failed"
	exit 1
fi

for PKG in $PKGS; do
	for FILE in `cur_file "$PKGLIST" "$PKG"`; do
		if [[ $FILE == yum-fastestmirror* ]]; then
			echo "SKIPPING FASTEST MIRROR"
			wget http://mirror.1000mbps.com/centos-vault/5.6/os/x86_64/CentOS/yum-fastestmirror-1.1.16-14.el5.centos.1.noarch.rpm
		else
			getting $FILE
			wget ${BASEURL}/${FILE}
		fi
		if [ $? -ne 0 ]; then
			echo "Retrieval of ${PKG} failed."
			exit 1
		fi
	done
done

# Remove Red Hat specific packages
echo "Removing Red Hat specific packages..."
if [ "$VER" == "6" ]; then
	rpm -e --nodeps redhat-release-server
	rv=$?
elif [ "$VER" == "5" ]; then
	rpm -e --nodeps redhat-release
	rv=$?
fi
if [ $rv -ne 0 ]; then
	echo "RPM erase of the redhat-release package failed."
	exit 1
fi
RHNPKGS=`rpm -qa | awk '/^rhn/{printf "%s ", $1}'`
if [ "$VER" == "6" ]; then
	RHNPKGS="${RHNPKGS} subscription-manager"
fi
yum --disableplugin=rhnplugin -y remove yum-rhn-plugin $RHNPKGS
if [ $? -ne 0 ]; then
	echo "YUM removal of Red Hat specific packages failed."
	exit 1
fi

echo "Force installing new CentOS packages..."
# Install CentOS packages
rpm -Uhv --force *.rpm
if [ $? -ne 0 ]; then
	echo "Forced installation of CentOS packages failed."
	exit 1
fi

# Import Key
echo "Importing the CentOS GPG package signing key"
rpm --import RPM-GPG-KEY-CentOS-${VER}
if [ $? -ne 0 ]; then
	echo "Failed to import the CentOS GPG package signing key."
	exit 1
fi

# Remove the temp directory
echo "Cleaning up temporary files..."
rm -rf /tmp/rhel2centos
if [ $? -ne 0 ]; then
	echo "Failed to remove /tmp/rhel2centos, please handle this manually."
fi

# Clean YUM
echo "Cleaning up YUM..."
yum clean all
rv=$?
if [ $rv -ne 0 ]; then
	echo "Failed to clean up YUM."
fi

# If we were told to upgrade packages, then do so, excludes stay in place
if [ -n "$UPGRADE" ] && [ $rv -eq 0 ]; then
	echo "Automatically performing a system wide package upgrade..."
	yum -y upgrade
else
	echo "Not automatically performing a system wide package upgrade."
fi

echo "Done."
exit 0


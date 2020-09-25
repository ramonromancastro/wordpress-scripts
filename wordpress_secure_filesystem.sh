#!/bin/bash


# wordpress_secure_filesystem.sh secure WordPress filesystem installation.
#
# Copyright (C) 2020  Ramón Román Castro <ramonromancastro@gmail.com>
# 
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

# Hardening WordPress: https://wordpress.org/support/article/hardening-wordpress/
# REVISIONES
#  1.0    2016/03/29  Versión original.
#  1.1    2016/03/29  wp-content/themes.
#  1.2    2017/03/03  Mensajes identificados con colores para identificarlos mejor.
#  1.4    2020/03/25  Primera versión publicada en GitHub.
#  1.5    2020/09/25  Añadido el archivo index.php en wp-content/uploads/ para evitar listing en el directorio.
#  1.5.1  2020/09/25  Añadido control de acceso a xmlrpc.php y wp.cron.php.

VERSION=1.5.1

# Constants
declare -A colors=( [debug]="\e[35m" [info]="\e[39m" [ok]="\e[32m" [warning]="\e[93m" [error]="\e[91m" )

# Functions
check_error() {
  if [ $? -gt 0 ]; then
    echo -e " ... ${colors[error]}error\e[0m"
  else
    echo -e " ... ${colors[ok]}ok\e[0m"
  fi
}

print_msg() {
	msg_color=$1
	msg_text=$2
	echo -en "${colors[$msg_color]}${msg_text}\e[0m"
}

print_help() {
cat <<-HELP

Script         : wordpress_secure_filesystem.sh
Versión        : ${VERSION}
Modified by    : Ramón Román Castro <ramonromancastro@gmail.com>

This script is used to fix permissions of a WordPress installation
you need to provide the following arguments:

  1) Path to your WordPress installation.
  2) Username of the user that you want to give files/directories ownership.
  3) HTTPD group name (defaults to apache for Apache).

Usage: (sudo) bash ${0##*/} --path=PATH --user=USER --group=GROUP
Example: (sudo) bash ${0##*/} --path=/usr/local/apache2/htdocs --user=john --group=apache

HELP
exit 0
}

if [ $(id -u) != 0 ]; then
  print_msg "warning" "You must run this with sudo or root.\n"
  print_help
  exit 1
fi

detected_user=$(httpd -t -D DUMP_RUN_CFG | grep "^User:" | cut -d '"' -f 2 2> /dev/null)
detected_group=$(httpd -t -D DUMP_RUN_CFG | grep "^Group:" | cut -d '"' -f 2 2> /dev/null)

print_msg "debug" "Apache HTTP Server user detected: ${detected_user}\n"
print_msg "debug" "Apache HTTP Server group detected: ${detected_group}\n"

path=$(pwd)
user=${detected_user:-}
group=${detected_group:-}

# Parse Command Line Arguments
while [ "$#" -gt 0 ]; do
  case "$1" in
    --path=*)
        path="${1#*=}"
		path="${path%/}"
        ;;
    --user=*)
        user="${1#*=}"
        ;;
    --group=*)
        group="${1#*=}"
        ;;
    --help) print_help;;
    *)
	  print_msg "warning" "Invalid argument, run --help for valid arguments.\n"
      exit 1
  esac
  shift
done

if [ -z "${path}" ] || [ ! -d "${path}/wp-admin" ] || [ ! -f "${path}/wp-config.php" ]; then
  print_msg "warning" "Please provide a valid WordPress path.\n"
  print_help
  exit 1
fi

if [ -z "${user}" ] || [[ $(id -un "${user}" 2> /dev/null) != "${user}" ]]; then
  print_msg "warning" "Please provide a valid user.\n"
  print_help
  exit 1
fi

if [ ! $(getent group "${group}") ]; then
  print_msg "warning" "Please provide a valid group.\n"
  print_help
  exit 1
fi

detected=$(grep -oP "^\\\$wp_version\s*=\s*['\"]\K(.*)(?=['\"])" "${path}/wp-includes/version.php")
detected=${detected:-N/A}
print_msg "debug" "WordPress detected: ${detected}\n"

#
# Add index.php at wp-content/uploads.
#

print_msg "info" "Creating index.php file in wp-content/uploads"
if [ ! -f $path/wp-content/uploads/index.php ]; then
  touch $path/wp-content/uploads/index.php
fi
check_error

#
# Restrict access to sensible files via .htaccess
#

cat << EOF >> $path/.htaccess

# Block WordPress sensible files from outside
<FilesMatch "(xmlrpc|wp\-cron)\.php$">
  <IfModule mod_authz_core.c>
    Require local
  </IfModule>
  <IfModule !mod_authz_core.c>
    Order Deny,Allow
    Deny from all
    Allow from 127.0.0.1
    Allow from ::1
    Allow from localhost
  </IfModule>
</FilesMatch>
EOF

#
# All files should be owned by your user account, and should be writable by you. Any file that needs write access from WordPress should be writable by the web server, if your hosting set up requires it, that may mean those files need to be group-owned by the user account used by the web server process.
#

print_msg "info" "Changing ownership of all contents to ${user}:${group}"
chown -R ${user}:${group} $path
check_error

#
# The root WordPress directory: all files should be writable only by your user account, except .htaccess if you want WordPress to automatically generate rewrite rules for you.
#

print_msg "info" "Changing permissions of all directories to rwxr-x---"
find $path -type d -exec chmod u=rwx,g=rx,o= '{}' \;
check_error

print_msg "info" "Changing permissions of all files to rw-r-----"
find $path -type f -exec chmod u=rw,g=r,o= '{}' \;
check_error

#
# The WordPress administration area: all files should be writable only by your user account.
#

print_msg "info" "Changing permissions of [wp-admin] directory to rwxr-x---"
chmod u=rwx,g=rx,o= $path/wp-admin
check_error

for x in $path/wp-admin; do
  print_msg "info" "Changing permissions of all directories inside [${x/$path/}] directory to rwxr-x---"
  find ${x} -type d -exec chmod u=rwx,g=rx,o= '{}' \;
  check_error

  print_msg "info" "Changing permissions of all files inside [${x/$path/}] directory to rw-r-----"  
  find ${x} -type f -exec chmod u=rw,g=r,o= '{}' \;
  check_error
done

#
# The bulk of WordPress application logic: all files should be writable only by your user account.
#

print_msg "info" "Changing permissions of [wp-includes] directory to rwxr-x---"
chmod u=rwx,g=rx,o= $path/wp-includes
check_error

for x in $path/wp-includes; do
  print_msg "info" "Changing permissions of all directories inside [${x/$path/}] directory to rwxr-x---"
  find ${x} -type d -exec chmod u=rwx,g=rx,o= '{}' \;
  check_error
  
  print_msg "info" "Changing permissions of all files inside [${x/$path/}] directory to rw-r-----"  
  find ${x} -type f -exec chmod u=rw,g=r,o= '{}' \;
  check_error
done

#
# User-supplied content: intended to be writable by your user account and the web server process.
#

print_msg "info" "Changing permissions of [wp-content] directory to rwxrwx---"
chmod u=rwx,g=rwx,o= $path/wp-content
check_error

for x in $path/wp-content; do
  print_msg "info" "Changing permissions of all directories inside [${x/$path/}] directory to rwxrwx---"
  find ${x} -type d -exec chmod u=rwx,g=rwx,o= '{}' \;
  check_error
  
  print_msg "info" "Changing permissions of all files inside [${x/$path/}] directory to rw-rw----"  
  find ${x} -type f -exec chmod u=rw,g=rw,o= '{}' \;
  check_error
done

#
# Plugin files: all files should be writable only by your user account.
#

print_msg "info" "Changing permissions of [wp-content/plugins] directory to rwxr-x---"
chmod u=rwx,g=rx,o= $path/wp-content/plugins
check_error

for x in $path/wp-content/plugins; do
  print_msg "info" "Changing permissions of all directories inside [${x/$path/}] directory to rwxr-x---"
  find ${x} -type d -exec chmod u=rwx,g=rx,o= '{}' \;
  check_error
  
  print_msg "info" "Changing permissions of all files inside [${x/$path/}] directory to rw-r-----"  
  find ${x} -type f -exec chmod u=rw,g=r,o= '{}' \;
  check_error
done

#
# Theme files. If you want to use the built-in theme editor, all files need to be writable by the web server process. If you do not want to use the built-in theme editor, all files can be writable only by your user account.
#

print_msg "info" "Changing permissions of [wp-content/themes] directory to rwxr-x---"
chmod u=rwx,g=rx,o= $path/wp-content/themes
check_error

for x in $path/wp-content/themes; do
  print_msg "info" "Changing permissions of all directories inside [${x/$path/}] directory to rwxr-x---"
  find ${x} -type d -exec chmod u=rwx,g=rx,o= '{}' \;
  check_error

  print_msg "info" "Changing permissions of all files inside [${x/$path/}] directory to rw-r-----"  
  find ${x} -type f -exec chmod u=rw,g=r,o= '{}' \;
  check_error
done

#
# The root WordPress directory: all files should be writable only by your user account, except .htaccess if you want WordPress to automatically generate rewrite rules for you.
#

print_msg "info" "Changing permissions of [.htaccess] files to rw-r-----"
find $path -type f -name .htaccess -exec chmod u=rw,g=r,o= '{}' \;
check_error

print_msg "info" "Changing permissions of [wp-config.php] files to rw-r-----"
find $path -type f -name wp-config.php -exec chmod u=rw,g=r,o= '{}' \;
check_error

print_msg "info" "Done setting proper permissions on files and directories\n"

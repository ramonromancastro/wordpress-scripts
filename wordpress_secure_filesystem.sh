#!/bin/bash

# wordpress_secure_filesystem.sh - Secure WordPress filesystem installation.
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
#  1.5.2  2026/05/25  Optimización de comandos find y redundancias eliminadas.
#  1.5.3  2026/10/08  Alineación con estándares de mínimo privilegio (SGID en uploads, base restrictiva 750/640).

VERSION=1.5.3

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

# Root check
if [ "$(id -u)" -ne 0 ]; then
  print_msg "warning" "You must run this with sudo or root.\n"
  print_help
  exit 1
fi

detected_user=$(httpd -t -D DUMP_RUN_CFG 2>/dev/null | grep "^User:" | cut -d '"' -f 2)
detected_group=$(httpd -t -D DUMP_RUN_CFG 2>/dev/null | grep "^Group:" | cut -d '"' -f 2)

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
    --help) 
        print_help
        ;;
    *)
        print_msg "warning" "Invalid argument, run --help for valid arguments.\n"
        exit 1
        ;;
  esac
  shift
done

# Validation
if [ -z "${path}" ] || [ ! -d "${path}/wp-admin" ] || [ ! -f "${path}/wp-config.php" ]; then
  print_msg "warning" "Please provide a valid WordPress path.\n"
  print_help
  exit 1
fi

if [ -z "${user}" ] || ! id -u "${user}" &>/dev/null; then
  print_msg "warning" "Please provide a valid user.\n"
  print_help
  exit 1
fi

if [ -z "${group}" ] || ! getent group "${group}" &>/dev/null; then
  print_msg "warning" "Please provide a valid group.\n"
  print_help
  exit 1
fi

detected=$(grep -oP "^\$wp_version\s*=\s*['\"]\K(.*)(?=['\"])" "${path}/wp-includes/version.php" 2>/dev/null)
detected=${detected:-N/A}
print_msg "debug" "WordPress detected: ${detected}\n"

#
# 1. Add index.php at wp-content/uploads to avoid directory listing
#
if [ -d "${path}/wp-content/uploads" ]; then
  print_msg "info" "Ensuring index.php file in wp-content/uploads"
  if [ ! -f "${path}/wp-content/uploads/index.php" ]; then
    touch "${path}/wp-content/uploads/index.php"
  fi
  check_error
fi

#
# 2. Restrict access to sensitive files via .htaccess (Idempotent check)
#
print_msg "info" "Configuring security rules in .htaccess"
if [ ! -f "${path}/.htaccess" ]; then
  touch "${path}/.htaccess"
fi

if grep -q "xmlrpc|wp\-cron" "${path}/.htaccess"; then
  print_msg "debug" " [rules already present]"
  echo -e " ... ${colors[ok]}ok\e[0m"
else
  cat << 'EOF' >> "${path}/.htaccess"

# Block WordPress sensitive files from outside
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
  check_error
fi

#
# 3. Ownership: assign non-root owner and web server group
#
print_msg "info" "Changing ownership of all contents to ${user}:${group}"
chown -R "${user}:${group}" "${path}"
check_error

#
# 4. Base permissions: Strict principle of least privilege across the entire tree
# Directories: 0750 (rwxr-x---)
# Files: 0640 (rw-r-----)
#
print_msg "info" "Setting baseline permissions (0750 dirs, 0640 files)"
find "${path}" -type d -exec chmod u=rwx,g=rx,o= '{}' +
check_error
find "${path}" -type f -exec chmod u=rw,g=r,o= '{}' +
check_error

#
# 5. Write exceptions: wp-content/uploads and wp-content/cache
# Needs group write access and SGID so newly generated/uploaded files inherit the web group.
# Directories: 2770 (rwxrws---)
# Files: 0660 (rw-rw----)
#
writable_dirs=("${path}/wp-content/uploads" "${path}/wp-content/cache")

for target_dir in "${writable_dirs[@]}"; do
  if [ -d "${target_dir}" ]; then
    folder_name="${target_dir##*/}"
    print_msg "info" "Setting writable permissions with SGID on wp-content/${folder_name}"
    find "${target_dir}" -type d -exec chmod u=rwx,g=rwxs,o= '{}' +
    check_error
    find "${target_dir}" -type f -exec chmod u=rw,g=rw,o= '{}' +
    check_error
  fi
done

# Soporte para WP Super Cache / plugins de caché en wp-content
cache_files=("${path}/wp-content/advanced-cache.php" "${path}/wp-content/wp-cache-config.php")

for target_file in "${cache_files[@]}"; do
  if [ -f "${target_file}" ]; then
    file_name="${target_file##*/}"
    print_msg "info" "Allowing write access for web server on wp-content/${file_name}"
    chmod u=rw,g=rw,o= "${target_file}"
    check_error
  fi
done

#
# 6. Sensitive files reinforcement
#
print_msg "info" "Securing wp-config.php and .htaccess"
chmod u=rw,g=r,o= "${path}/wp-config.php" 2>/dev/null
chmod u=rw,g=r,o= "${path}/.htaccess" 2>/dev/null
check_error

print_msg "info" "Done setting proper permissions on files and directories\n"
exit 0

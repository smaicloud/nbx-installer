#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

CURDIR=`pwd`
POSTGRESPW=$(tr -cd '[:alnum:]' < /dev/urandom | fold -w25 | head -n1)
SECRET_KEY=$(tr -cd '[:alnum:]' < /dev/urandom | fold -w55 | head -n1)
HOSTNAME=$hostname

clear

if [[ $EUID -ne 0 ]]; then
   echo -e "------------------------------------------------------------------"
   echo -e "${RED}must be run as root.${NC}"
   echo -e "------------------------------------------------------------------"
   exit 1
fi

function netbox_new_version {
  echo -e "${GREEN}Enter the netbox version (without "v") and press Enter:${NC}"
  read -e VERSION
clear
}

function os_check {
 if [[ $(lsb_release -d) == *20.04* ]]; then
   UBUNTU_VERSION=20
else
   echo -e "-----------------------------------------------------------------------"
   echo -e "${RED}You are not running Ubuntu 20.04. Installation cancelled.${NC}"
   echo -e "-----------------------------------------------------------------------"
   exit 1
fi
}

function netbox_check {
 if [[ -d /opt/netbox ]]; then 
   echo -e "-------------------------------------------------------------------------------"
   echo -e "${RED}Netbox installation found in /opt/netbox. Installation cancelled.${NC}"
   echo -e "-------------------------------------------------------------------------------"
   exit 1
fi
clear
}

function get_ip {
INTERFACE=$(netstat -i | awk '!/Kernel|Iface|lo/ {print $1," "}')
IP=($(curl --interface $INTERFACE --connect-timeout 2 -s4 icanhazip.com))
clear
}

function prepare_system {
echo -e "----------------------------------------------------"
echo -e "Loading Ubuntu updates..."
echo -e "Please be patient and wait a moment..."
echo -e "----------------------------------------------------"
DEBIAN_FRONTEND=noninteractive apt update > /dev/null 2>&1
clear
if [ "$?" -gt "0" ];
  then
    echo -e "-------------------------------------------------------------------------"
    echo -e "${RED}System update not successful. Check out manually apt update.${NC}"
    echo -e "-------------------------------------------------------------------------"
 exit 1
fi
clear
}

function postgres {
echo -e "----------------------------------------------------"
echo -e "Setup PostgreSQL..."
echo -e "----------------------------------------------------"
apt install -y postgresql
systemctl start postgresql
systemctl enable postgresql
su - postgres -c "psql -c 'CREATE DATABASE netbox;'"
su - postgres -c "psql -c \"CREATE USER netbox WITH PASSWORD '$POSTGRESPW';\""
su - postgres -c "psql -c 'GRANT ALL PRIVILEGES ON DATABASE netbox TO netbox;'"
clear
if [ "$?" -gt "0" ];
  then
    echo -e "----------------------------------------------------------"
    echo -e "${RED}PostgreSQL installation not successful.${NC}"
    echo -e "----------------------------------------------------------"
 exit 1
fi
clear
}

function redis {
echo -e "----------------------------------------------------"
echo -e "Setup Redis..."
echo -e "----------------------------------------------------"
sudo apt install -y redis-server
if [ "$?" -gt "0" ];
  then
    echo -e "----------------------------------------------------------"
    echo -e "${RED}Redis installation not successful.${NC}"
    echo -e "----------------------------------------------------------"
 exit 1
fi
clear
}

function netbox {
echo -e "----------------------------------------------------"
echo -e "Setup netbox..."
echo -e "----------------------------------------------------"
apt install -y python3 python3-pip python3-venv python3-dev build-essential libxml2-dev libxslt1-dev libffi-dev libpq-dev libssl-dev zlib1g-dev
wget https://github.com/netbox-community/netbox/archive/v${VERSION}.tar.gz
tar -xzf v${VERSION}.tar.gz -C /opt
ln -s /opt/netbox-${VERSION}/ /opt/netbox
adduser --system --group netbox
chown --recursive netbox /opt/netbox/netbox/media/
cp /opt/netbox/netbox/netbox/configuration.example.py /opt/netbox/netbox/netbox/configuration.py
sed -i "s/ALLOWED_HOSTS = \[\]/ALLOWED_HOSTS = \['*'\]/" /opt/netbox/netbox/netbox/configuration.py
sed -i "s/'USER': '',/'USER': 'netbox',/" /opt/netbox/netbox/netbox/configuration.py
sed -i "0,/'PASSWORD':/ s/'PASSWORD': '',/'PASSWORD': '$POSTGRESPW',/" /opt/netbox/netbox/netbox/configuration.py
sed -i "s/SECRET_KEY = ''/SECRET_KEY = '${SECRET_KEY}'/" /opt/netbox/netbox/netbox/configuration.py
/opt/netbox/upgrade.sh
rm v$VERSION.tar.gz
if [ "$?" -gt "0" ];
  then
    echo -e "----------------------------------------------------------"
    echo -e "${RED}netbox installation not successful.${NC}"
    echo -e "----------------------------------------------------------"
 exit 1
fi
clear
}

function netboxsuperuser {
echo -e "----------------------------------------------------"
echo -e "Setup Super User..."
echo -e "----------------------------------------------------"
source /opt/netbox/venv/bin/activate
cd /opt/netbox/netbox
python3 manage.py createsuperuser
cd ~
if [ "$?" -gt "0" ];
  then
    echo -e "----------------------------------------------------------"
    echo -e "${RED}Super User config not successful.${NC}"
    echo -e "----------------------------------------------------------"
 exit 1
fi
clear
}

function housekeeping {
echo -e "----------------------------------------------------"
echo -e "Setup Housekeeping..."
echo -e "----------------------------------------------------"
chmod +x /opt/netbox/contrib/netbox-housekeeping.sh
ln -s /opt/netbox/contrib/netbox-housekeeping.sh /etc/cron.daily/netbox-housekeeping
if [ "$?" -gt "0" ];
  then
    echo -e "----------------------------------------------------------"
    echo -e "${RED}Housekeeping config not successful.${NC}"
    echo -e "----------------------------------------------------------"
 exit 1
fi
clear
}

function gunicorn {
echo -e "----------------------------------------------------"
echo -e "Setup Gunicorn..."
echo -e "----------------------------------------------------"
cp /opt/netbox/contrib/gunicorn.py /opt/netbox/gunicorn.py
cp -v /opt/netbox/contrib/*.service /etc/systemd/system/
systemctl daemon-reload
systemctl start netbox netbox-rq
systemctl enable netbox netbox-rq
if [ "$?" -gt "0" ];
  then
    echo -e "----------------------------------------------------------"
    echo -e "${RED}Gunicorn config not successful.${NC}"
    echo -e "----------------------------------------------------------"
 exit 1
fi
clear
}

function nginx {
echo -e "----------------------------------------------------"
echo -e "Setup nginx..."
echo -e "----------------------------------------------------"
apt install -y nginx
touch /etc/nginx/sites-available/netbox
  cat << EOF > /etc/nginx/sites-available/netbox
server {
    listen 80;
    listen [::]:80;
#   listen 443 ssl;

    # CHANGE THIS TO YOUR SERVER'S NAME
    server_name netbox;

#    ssl_certificate /etc/ssl/certs/netbox.crt;
#    ssl_certificate_key /etc/ssl/private/netbox.key;

    client_max_body_size 25m;

    location /static/ {
        alias /opt/netbox/netbox/static/;
    }

    location / {
        proxy_pass http://127.0.0.1:8001;
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}

#server {
#    # Redirect HTTP traffic to HTTPS
#    listen 80;
#    server_name _;
#    return 301 https://\$host\$request_uri;
#}

EOF
rm /etc/nginx/sites-enabled/default
ln -s /etc/nginx/sites-available/netbox /etc/nginx/sites-enabled/netbox
systemctl restart nginx
if [ "$?" -gt "0" ];
  then
    echo -e "----------------------------------------------------------"
    echo -e "${RED}nginx config not successful.${NC}"
    echo -e "----------------------------------------------------------"
 exit 1
fi
clear
}

function backup {
git clone https://github.com/tom-ua/netbox-postgres-backup.git
chmod +x netbox-postgres-backup/pg_backup*.sh
clear
}

function summary {
echo -e "======================================================================================="
echo -e "Installation Summary:"
echo -e "----------------------------------------------------------------------------------"
echo -e "${GREEN}Installed netbox version:${NC} ${RED}$VERSION${NC}"
echo -e "----------------------------------------------------------------------------------"
echo -e "${GREEN}Open your browser:${NC} ${RED}http://$IP${NC}"
echo -e "----------------------------------------------------------------------------------"
echo -e "${GREEN}PostgreSQL password:${NC} ${RED}$POSTGRESPW${NC}"
echo -e "----------------------------------------------------------------------------------"
echo -e "${GREEN}Secret Key:${NC} ${RED}$SECRET_KEY${NC}"
echo -e "----------------------------------------------------------------------------------"
echo -e "${RED}Don't forget the SSL cert! /etc/nginx/sites-enabled/netbox.conf${NC}" 
echo -e "======================================================================================"
}

function netbox_old_version {
  echo -e "${GREEN}Enter  your current netbox version (without "v") and press Enter:${NC}"
  read -e OLDVERSION
clear
}

function netbox_update {
echo -e "----------------------------------------------------"
echo -e "Update netbox..."
echo -e "----------------------------------------------------"
wget https://github.com/netbox-community/netbox/archive/v${VERSION}.tar.gz
tar -xzf v${VERSION}.tar.gz -C /opt
ln -sfn /opt/netbox-${VERSION}/ /opt/netbox
cp /opt/netbox-${OLDVERSION}/local_requirements.txt /opt/netbox/
cp /opt/netbox-${OLDVERSION}/netbox/netbox/configuration.py /opt/netbox/netbox/netbox/
cp /opt/netbox-${OLDVERSION}/netbox/netbox/ldap_config.py /opt/netbox/netbox/netbox/
cp -pr /opt/netbox-$OLDVERSION/netbox/media/ /opt/netbox/netbox/
cp -r /opt/netbox-$OLDVERSION/netbox/scripts /opt/netbox/netbox/
cp -r /opt/netbox-$OLDVERSION/netbox/reports /opt/netbox/netbox/
cp /opt/netbox-$OLDVERSION/gunicorn.py /opt/netbox/
/opt/netbox/upgrade.sh
systemctl restart netbox netbox-rq
rm v${VERSION}.tar.gz
if [ "$?" -gt "0" ];
  then
    echo -e "----------------------------------------------------------"
    echo -e "${RED}netbox update not successful.${NC}"
    echo -e "----------------------------------------------------------"
 exit 1
fi
}

function update_summary {
echo -e "======================================================================================="
echo -e "Update Summary:"
echo -e "----------------------------------------------------------------------------------"
echo -e "${GREEN}Updated netbox from ${RED}v$OLDVERSION to v$VERSION${NC}"
echo -e "----------------------------------------------------------------------------------"
echo -e "${RED}If upgrading from a release prior to NetBox v3.0, check that a cron task\n
(or similar scheduled process) has been configured to run NetBox's nightly\n
housekeeping command.${NC}"
echo -e "======================================================================================"
exit 0
}

##### Update #####
function update {
  os_check
  netbox_old_version
  netbox_new_version
  netbox_update
  update_summary
}

echo "Do you want to update or install netbox?"
select uic in "Update" "Install" "Cancel"; do
  case $uic in
    Update ) clear;update ;;
    Install ) break ;;
    Cancel ) exit ;;
  esac
done

##### Install #####
clear
netbox_new_version
os_check
netbox_check
get_ip
prepare_system
postgres
redis
netbox
netboxsuperuser
housekeeping
gunicorn
nginx
backup
summary


#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

POSTGRESPW=$(tr -cd '[:alnum:]' < /dev/urandom | fold -w25 | head -n1)
SECRET_KEY=$(tr -cd '[:alnum:]' < /dev/urandom | fold -w55 | head -n1)

clear

if [[ $EUID -ne 0 ]]; then
   echo -e "------------------------------------------------------------------"
   echo -e "${RED}must be run as root.${NC}"
   echo -e "------------------------------------------------------------------"
   exit 1
fi

function netbox_new_version {
  echo -e "${GREEN}Enter the NetBox version (without \"v\") and press Enter:${NC}"
  read -e VERSION
  clear
}

# Nur NetBox 4.4+ zulassen
function check_version_supported {
  local major minor
  major="$(echo "$VERSION" | cut -d. -f1)"
  minor="$(echo "$VERSION" | cut -d. -f2)"

  if [[ -z "$major" || -z "$minor" ]]; then
    echo -e "${RED}Invalid version: $VERSION (expected e.g. 4.4 or 4.4.7).${NC}"
    exit 1
  fi

  if (( major < 4 )) || (( major == 4 && minor < 4 )); then
    echo -e "${RED}This script only supports NetBox versions >= 4.4.x.${NC}"
    exit 1
  fi
}

# Nur Ubuntu 24.04 erlauben
function os_check {
  local desc
  desc=$(lsb_release -d 2>/dev/null || echo "")

  if echo "$desc" | grep -q "24.04"; then
      return 0
  else
      echo -e "${RED}This script supports only Ubuntu 24.04 LTS.${NC}"
      exit 1
  fi
}

function netbox_check {
 if [[ -d /opt/netbox ]]; then
   echo -e "${RED}NetBox installation found in /opt/netbox. Installation cancelled.${NC}"
   exit 1
 fi
 clear
}

function get_ip {
  IP=$(hostname -I | awk '{print $1}')
  clear
}

function prepare_system {
  echo -e "----------------------------------------------------"
  echo -e "Updating Ubuntu..."
  echo -e "----------------------------------------------------"
  DEBIAN_FRONTEND=noninteractive apt update > /dev/null 2>&1
  clear
}

function postgres {
  echo -e "----------------------------------------------------"
  echo -e "Setup PostgreSQL..."
  echo -e "----------------------------------------------------"
  DEBIAN_FRONTEND=noninteractive apt install -y postgresql
  systemctl enable --now postgresql

  su - postgres -c "psql -c 'CREATE DATABASE netbox;'" 
  su - postgres -c "psql -c \"CREATE USER netbox WITH PASSWORD '$POSTGRESPW';\""
  su - postgres -c "psql -c 'GRANT ALL PRIVILEGES ON DATABASE netbox TO netbox;'"

  clear
}

function redis {
  echo -e "----------------------------------------------------"
  echo -e "Setup Redis..."
  echo -e "----------------------------------------------------"
  DEBIAN_FRONTEND=noninteractive apt install -y redis-server
  systemctl enable --now redis-server
  clear
}

function netbox {
  echo -e "----------------------------------------------------"
  echo -e "Setup NetBox..."
  echo -e "----------------------------------------------------"

  apt install -y python3 python3-pip python3-venv python3-dev build-essential \
    libxml2-dev libxslt1-dev libffi-dev libpq-dev libssl-dev zlib1g-dev

  wget https://github.com/netbox-community/netbox/archive/v${VERSION}.tar.gz
  tar -xzf v${VERSION}.tar.gz -C /opt
  ln -s /opt/netbox-${VERSION}/ /opt/netbox

  adduser --system --group netbox
  chown -R netbox /opt/netbox/netbox/media/

  cp /opt/netbox/netbox/netbox/configuration_example.py /opt/netbox/netbox/netbox/configuration.py

  sed -i "s/ALLOWED_HOSTS = \[\]/ALLOWED_HOSTS = \['*'\]/" /opt/netbox/netbox/netbox/configuration.py
  sed -i "s/'USER': '',/'USER': 'netbox',/" /opt/netbox/netbox/netbox/configuration.py
  sed -i "0,/'PASSWORD':/ s/'PASSWORD': '',/'PASSWORD': '$POSTGRESPW',/" /opt/netbox/netbox/netbox/configuration.py
  sed -i "s/SECRET_KEY = ''/SECRET_KEY = '${SECRET_KEY}'/" /opt/netbox/netbox/netbox/configuration.py

  /opt/netbox/upgrade.sh
  rm v${VERSION}.tar.gz
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
  clear
}

function gunicorn {
  echo -e "----------------------------------------------------"
  echo -e "Setup Gunicorn + systemd..."
  echo -e "----------------------------------------------------"

  cp /opt/netbox/contrib/gunicorn.py /opt/netbox/gunicorn.py
  cp -v /opt/netbox/contrib/*.service /etc/systemd/system/

  systemctl daemon-reload
  systemctl enable --now netbox netbox-rq
  clear
}

function nginx {
  echo -e "----------------------------------------------------"
  echo -e "Setup nginx..."
  echo -e "----------------------------------------------------"

  apt install -y nginx

  cat << EOF > /etc/nginx/sites-available/netbox
server {
    listen 80;
    listen [::]:80;

    server_name netbox;

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
EOF

  rm -f /etc/nginx/sites-enabled/default
  ln -s /etc/nginx/sites-available/netbox /etc/nginx/sites-enabled/netbox

  systemctl restart nginx
  clear
}

# Optional: NetBox Discovery Device-Discovery Backend (ohne Container)
function install_netbox_discovery {
  echo -e "----------------------------------------------------"
  echo -e "Install NetBox Discovery (device-discovery backend)..."
  echo -e "----------------------------------------------------"

  # nmap für Network Discovery, falls später genutzt
  DEBIAN_FRONTEND=noninteractive apt install -y nmap

  # eigenes venv für Discovery
  python3 -m venv /opt/netbox-discovery-venv
  source /opt/netbox-discovery-venv/bin/activate
  pip install --upgrade pip
  pip install netboxlabs-device-discovery
  deactivate

  # Environment-File für Diode/Discovery
  cat << 'EOF' > /etc/netbox-discovery.env
# NetBox Discovery / Device-Discovery Backend
# WICHTIG: Diese Werte musst du an deinen Diode-Server anpassen!

# Diode gRPC Target, z.B.: grpc://diode.example.local:8080/diode
DIODE_TARGET=grpc://CHANGE-ME:8080/diode

# OAuth Client ID + Secret aus Diode
DIODE_CLIENT_ID=CHANGE-ME
DIODE_CLIENT_SECRET=CHANGE-ME

# HTTP Bind (interner Status-Port des Backends, optional)
LISTEN_HOST=0.0.0.0
LISTEN_PORT=9000
EOF

  # systemd-Service für device-discovery
  cat << 'EOF' > /etc/systemd/system/netbox-device-discovery.service
[Unit]
Description=NetBox Device Discovery backend (Orb/Diode)
After=network.target

[Service]
Type=simple
EnvironmentFile=/etc/netbox-discovery.env
WorkingDirectory=/opt/netbox-discovery-venv
ExecStart=/opt/netbox-discovery-venv/bin/device-discovery \
  -s ${LISTEN_HOST} -p ${LISTEN_PORT} \
  -t ${DIODE_TARGET} \
  -c ${DIODE_CLIENT_ID} \
  -k ${DIODE_CLIENT_SECRET}
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now netbox-device-discovery.service || true

  echo -e "${GREEN}NetBox Discovery device backend installed.${NC}"
  echo -e "${GREEN}Edit ${RED}/etc/netbox-discovery.env${GREEN} and point it to your Diode server.${NC}"
  echo -e "${GREEN}Also make sure the Diode NetBox plugin is installed and configured in NetBox.${NC}"
  echo
}

function backup {
  git clone https://github.com/smaicloud/nbx-postgres-backup.git
  chmod +x nbx-postgres-backup/pg_backup*.sh 2>/dev/null || true
  clear
}

# Credentials in Datei statt im Terminal
function write_credentials {
  local credfile="/root/netbox-install-credentials.txt"
  {
    echo "NetBox version: $VERSION"
    echo "PostgreSQL password: $POSTGRESPW"
    echo "Secret Key: $SECRET_KEY"
  } > "$credfile"
  chmod 600 "$credfile"
}

function summary {
  write_credentials
  echo -e "======================================================================================="
  echo -e "Installation Summary:"
  echo -e "----------------------------------------------------------------------------------"
  echo -e "${GREEN}Installed NetBox version:${NC} ${RED}$VERSION${NC}"
  echo -e "----------------------------------------------------------------------------------"
  echo -e "${GREEN}Open in browser:${NC} ${RED}http://$IP${NC}"
  echo -e "----------------------------------------------------------------------------------"
  echo -e "${GREEN}Credentials saved to:${NC} ${RED}/root/netbox-install-credentials.txt${NC}"
  echo -e "----------------------------------------------------------------------------------"
  echo -e "${RED}Don't forget SSL configuration in /etc/nginx/sites-enabled/netbox${NC}"
  echo -e "======================================================================================="
}

function netbox_old_version {
  echo -e "${GREEN}Enter your current NetBox version (without \"v\") and press Enter:${NC}"
  read -e OLDVERSION
  clear
}

function netbox_update {
  echo -e "----------------------------------------------------"
  echo -e "Update NetBox..."
  echo -e "----------------------------------------------------"

  if [ ! -d "/opt/netbox-${OLDVERSION}" ]; then
    echo -e "${RED}/opt/netbox-${OLDVERSION} not found. Wrong old version entered.${NC}"
    exit 1
  fi

  wget https://github.com/netbox-community/netbox/archive/v${VERSION}.tar.gz
  tar -xzf v${VERSION}.tar.gz -C /opt
  ln -sfn /opt/netbox-${VERSION}/ /opt/netbox

  cp /opt/netbox-${OLDVERSION}/local_requirements.txt /opt/netbox/ 2>/dev/null || true
  cp /opt/netbox-${OLDVERSION}/netbox/netbox/configuration.py /opt/netbox/netbox/netbox/ || true
  cp /opt/netbox-${OLDVERSION}/netbox/netbox/ldap_config.py /opt/netbox/netbox/netbox/ || true
  cp -pr /opt/netbox-$OLDVERSION/netbox/media/ /opt/netbox/netbox/ || true
  cp -r /opt/netbox-$OLDVERSION/netbox/scripts /opt/netbox/netbox/ || true
  cp -r /opt/netbox-$OLDVERSION/netbox/reports /opt/netbox/netbox/ || true
  cp /opt/netbox-$OLDVERSION/gunicorn.py /opt/netbox/ || true

  /opt/netbox/upgrade.sh
  systemctl restart netbox netbox-rq
  rm v${VERSION}.tar.gz
}

function update_summary {
  echo -e "======================================================================================="
  echo -e "Update Summary:"
  echo -e "${GREEN}Updated NetBox from ${RED}$OLDVERSION${NC} to ${RED}$VERSION${NC}"
  echo -e "${GREEN}Housekeeping is handled internally in NetBox 4.4+.${NC}"
  echo -e "======================================================================================="
  exit 0
}

##### Update #####
function update {
  os_check
  netbox_old_version
  netbox_new_version
  check_version_supported
  netbox_update
  update_summary
}

echo "Do you want to update or install NetBox?"
select uic in "Update" "Install" "Cancel"; do
  case $uic in
    Update ) clear; update ;;
    Install ) break ;;
    Cancel ) exit ;;
  esac
done

##### Install #####
clear
netbox_new_version
check_version_supported
os_check
netbox_check
get_ip
prepare_system
postgres
redis
netbox
netboxsuperuser
gunicorn
nginx

echo
echo "Do you want to install NetBox Discovery (device-discovery backend) on this host?"
select dis in "Yes" "No"; do
  case $dis in
    Yes ) install_netbox_discovery; break ;;
    No )  echo "Skipping NetBox Discovery installation."; break ;;
  esac
done

backup
summary

#!/bin/bash
echo "====================================================="
echo " Sidetron Netzwerkleitung - MeshCentral LXC Installer"
echo "====================================================="
echo ""

# 1. Benutzerabfragen
# WICHTIG: Stellt sicher, dass das Skript im Terminal interaktiv ausgeführt wird!
read -p "1. Bitte Container ID eingeben (z.B. 200): " CTID
read -p "2. Bitte IP-Adresse mit Subnetz eingeben (z.B. 192.168.178.50/24): " IP_ADDR
read -p "3. Bitte Gateway IP eingeben (z.B. 192.168.178.1): " GATEWAY
read -p "4. Bitte MAC-Adresse eingeben (leer lassen für auto-generiert): " MAC_ADDR
read -s -p "5. Bitte Root-Passwort für den neuen Container vergeben: " CT_PASSWORD
echo ""
echo ""

# Standard-Storage für Container-Disks in Proxmox
STORAGE="local-lvm"

echo "[Info] Aktualisiere Template-Liste und lade Ubuntu 22.04 herunter..."
pveam update >/dev/null 2>&1
TEMPLATE_FILE=$(pveam available -section system | grep ubuntu-22.04-standard | awk '{print $2}' | head -n 1)

if [ -z "$TEMPLATE_FILE" ]; then
  echo "[Fehler] Konnte kein Ubuntu 22.04 Template finden."
  exit 1
fi

pveam download local $TEMPLATE_FILE >/dev/null 2>&1
TEMPLATE_PATH="local:vztmpl/${TEMPLATE_FILE##*/}"

NET_CONF="name=eth0,bridge=vmbr0,gw=$GATEWAY,ip=$IP_ADDR"
if [ ! -z "$MAC_ADDR" ]; then
    NET_CONF="$NET_CONF,hwaddr=$MAC_ADDR"
fi

echo "[Info] Erstelle LXC Container $CTID..."
pct create $CTID $TEMPLATE_PATH -arch amd64 -hostname meshcentral -net0 $NET_CONF -password $CT_PASSWORD -cores 2 -memory 4096 -rootfs $STORAGE:30 -ostype ubuntu -unprivileged 1

echo "[Info] Starte Container $CTID..."
pct start $CTID

echo "[Info] Warte 15 Sekunden, bis das Netzwerk des Containers bereit ist..."
sleep 15

echo "[Info] Generiere MeshCentral-Setup..."
cat << 'EOF' > /tmp/mesh_setup.sh
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive

# Updates & Basis-Pakete
apt-get update && apt-get upgrade -y
apt-get install -y curl software-properties-common ufw nano gnupg wget

# Node.js & MongoDB
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs mongodb
systemctl enable mongodb
systemctl start mongodb

# User & Verzeichnisse
useradd -r -s /sbin/nologin meshcentral
mkdir -p /opt/meshcentral
chown -R meshcentral:meshcentral /opt/meshcentral

# MeshCentral Installation
cd /opt/meshcentral
sudo -u meshcentral npm install meshcentral

# Systemd Service
cat << 'SRV' > /etc/systemd/system/meshcentral.service
[Unit]
Description=Sidetron MeshCentral Server
After=network.target mongodb.service

[Service]
Type=simple
LimitNOFILE=8192
User=meshcentral
WorkingDirectory=/opt/meshcentral
Environment=NODE_ENV=production
ExecStart=/usr/bin/node /opt/meshcentral/node_modules/meshcentral
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SRV

systemctl daemon-reload
systemctl enable meshcentral
systemctl start meshcentral

# Firewall
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
EOF

echo "[Info] Führe Installation im Container aus (das kann ein paar Minuten dauern)..."
pct push $CTID /tmp/mesh_setup.sh /root/mesh_setup.sh
pct exec $CTID -- bash /root/mesh_setup.sh

rm /tmp/mesh_setup.sh
pct exec $CTID -- rm /root/mesh_setup.sh

echo "====================================================="
echo " Sidetron Setup abgeschlossen!"
echo " MeshCentral ist nun erreichbar auf HTTPS unter IP: $IP_ADDR"
echo "====================================================="

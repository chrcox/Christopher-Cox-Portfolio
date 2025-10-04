#!/bin/bash
set -e

# --- CONFIGURATION ---
WAZUH_MANAGER="${WAZUH_MANAGER:-[REDACTED]}"
WAZUH_AGENT_GROUP="${WAZUH_AGENT_GROUP:-[REDACTED]}"
WAZUH_AGENT_NAME="${WAZUH_AGENT_NAME:-$(hostname)}"
WAZUH_AGENT_DEB="wazuh-agent_4.12.0-1_amd64.deb"
CERT_DIR="/var/ossec/etc"

# --- GRABBING PUBLIC IP FOR CERTIFICATE ---
echo "Fetching agent public IP..."
AGENT_PUBLIC_IP=$(curl -s http://checkip.amazonaws.com || curl -s ifconfig.me || curl -s ipinfo.io/ip)

if [[ -z "$AGENT_PUBLIC_IP" ]]; then
  echo "Error: Could not determine public IP. Falling back to hostname."
  AGENT_PUBLIC_IP=$(hostname)
fi

# --- VALIDATE CA FILES ---
if [[ ! -f ./root-ca.pem ]]; then
  echo "Error: root-ca.pem not found in current directory! Both the root-ca.pem and root-ca.key are required for authorisation."
  exit 1
fi

if [[ ! -f ./root-ca.key ]]; then
  echo "Error: root-ca.key not found in current directory! Both the root-ca.pem and root-ca.key are required for authorisation."
  exit 1
fi

# --- AGENT INSTALLATION ---
echo "Installing Wazuh Agent..."
wget -q https://packages.wazuh.com/4.x/apt/pool/main/w/wazuh-agent/$WAZUH_AGENT_DEB
sudo dpkg -i $WAZUH_AGENT_DEB

sudo curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | sudo gpg --no-default-keyring --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg --import && sudo chmod 644 /usr/share/keyrings/wazuh.gpg
echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" | sudo tee -a /etc/apt/sources.list.d/wazuh.list
sudo apt-get update


# --- MOVE CA FILES ---
echo "Setting up CA..."
cp ./root-ca.pem /tmp/root-ca.pem
cp ./root-ca.key /tmp/root-ca.key

# --- GENERATING CSR AND AGENT KEY ---
echo "Generating and signing certificates..."
openssl req -new -nodes -newkey rsa:4096 \
  -keyout /tmp/sslagent.key \
  -out /tmp/sslagent.csr \
  -batch \
  -subj "/C=US/CN=$WAZUH_AGENT_NAME"

openssl x509 -req -days 365 \
  -in /tmp/sslagent.csr \
  -CA /tmp/root-ca.pem \
  -CAkey /tmp/root-ca.key \
  -out /tmp/sslagent.cert \
  -CAcreateserial

sudo mv /tmp/sslagent.cert /var/ossec/etc/
sudo mv /tmp/sslagent.key /var/ossec/etc/
sudo mv /tmp/root-ca.pem /var/ossec/etc/

sudo chown wazuh:wazuh /var/ossec/etc/sslagent.cert /var/ossec/etc/sslagent.key /var/ossec/etc/root-ca.pem
sudo chmod 640 /var/ossec/etc/sslagent.cert /var/ossec/etc/sslagent.key /var/ossec/etc/root-ca.pem

# --- UPDATING OSSEC WITH TLS ---
echo "Adding TLS config to ossec.conf..."
sudo sed -i '/<ossec_config>/,/<\/ossec_config>/!b;//!d' $CERT_DIR/ossec.conf
sudo sed -i '/<client>/,/<\/client>/d' $CERT_DIR/ossec.conf

sudo sed -i "/<ossec_config>/a\\
  <client>\n\
    <enrollment>\n\
      <agent_name>$WAZUH_AGENT_NAME</agent_name>\n\
      <enabled>yes</enabled>\n\
      <manager_address>[REDACTED]</manager_address>\n\
      <port>1515</port>\n\
      <ssl_cipher>HIGH:!ADH:!EXP:!MD5:!RC4:!3DES:!CAMELLIA:@STRENGTH</ssl_cipher>\n\
      <server_ca_path>$CERT_DIR/root-ca.pem</server_ca_path>\n\
      <agent_certificate_path>$CERT_DIR/sslagent.cert</agent_certificate_path>\n\
      <agent_key_path>$CERT_DIR/sslagent.key</agent_key_path>\n\
      <auto_method>yes</auto_method>\n\
    </enrollment>\n\
    <server>\n\
      <address>[REDACTED]</address>\n\
      <port>1514</port>\n\
      <protocol>tcp</protocol>\n\
    </server>\n\
    <config-profile>ubuntu, ubuntu24, ubuntu24.04</config-profile>\n\
    <notify_time>10</notify_time>\n\
    <time-reconnect>60</time-reconnect>\n\
    <auto_restart>yes</auto_restart>\n\
    <crypto_method>aes</crypto_method>\n\
  </client>" $CERT_DIR/ossec.conf


# --- ENABLE REMOTE COMMANDS ---
echo "Enabling Remote Commands..."
sudo bash -c 'echo "logcollector.remote_commands=1" >> /var/ossec/etc/local_internal_options.conf'

# --- CLAMAV INTEGRATION ---
echo "Installing ClamAV..."
sudo apt update && sudo apt install -y clamav clamav-daemon
sudo bash -c 'echo "LogSyslog true" >> /etc/clamav/clamd.conf'

# --- UFW CONFIGURATION ---
echo "Configuring UFW logging..."
sudo ufw logging on
sudo ufw logging high
sudo ufw allow [REDACTED]/tcp
sudo ufw --force enable
sudo usermod -aG adm wazuh

# --- DISABLE WAZUH UPDATES ---
echo "Disabling Wazuh updates..."
sudo sed -i "s/^deb/#deb/" /etc/apt/sources.list.d/wazuh.list
sudo apt-get update

# --- ENABLE & START SERVICE ---
echo "Starting Wazuh Agent..."
sudo systemctl daemon-reload
sudo systemctl enable wazuh-agent
sudo systemctl restart wazuh-agent

# --- VERIFY AGENT STATUS ---
if systemctl is-active --quiet wazuh-agent; then
  echo "Wazuh Agent is successfully running!"
else
  echo "Wazuh Agent failed to start!"
fi

# --- FILE CLEAN UP ---
echo "Cleaning up files..."
rm -f $WAZUH_AGENT_DEB
rm -f /tmp/sslagent.csr
rm -f /tmp/root-ca.srl
sudo shred -u /tmp/root-ca.key
# UNCOMMENT BELOW FOR NON-TEST ENVIRONMENT
# sudo shred */root-ca.key

echo "Linux agent installation and configuration complete!"

# --- PROMPT FOR FRESHCLAM ---
read -p "It is recommended to run freshclam to update ClamAV's virus database. Do you want to run freshclam now? (y/N): " RUN_FRESHCLAM
if [[ "$RUN_FRESHCLAM" =~ ^[Yy]$ ]]; then
  echo "Running freshclam..."
  sudo freshclam
else
  echo "Skipping freshclam."
fi
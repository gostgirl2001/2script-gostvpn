# GOST VPN - RU / Intl builds

Run each script as root user. If not logged in as root user, append 'sudo' before executing file, e.g 'sudo ./install_gostvpn_server_ru'.

## Order:

1) ru/intl server file (on server) - e.g './install_gostvpn_server_ru'
2) ru/intl client file (on client machine), IMPORTANT: must include IP address of server - e.g './install_gostvpn_client_ru [IP_ADDRESS]' 

## File compatibility:

_ru: for Russian IP ranges supporting live downloads of native Astra Linux dependencies.

_intl: for IP ranges outside Russia, uses available archived Debian equivalents. Functionality unchanged. 

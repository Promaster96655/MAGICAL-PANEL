#!/bin/bash
set -euo pipefail

# CONFIG
PHP_VERSION="8.3"
APP_PORT=80

DB_NAME="magicalpanel"
DB_USER="magicaluser"
DB_PASS="MagicalDbPass123!"

ADMIN_EMAIL="admin@magicalpanel.local"
ADMIN_PASS="AdminPass123!"

APP_DIR="/var/www/magicalpanel"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

function info { echo -e "${BLUE}[INFO]${NC} $1"; }
function success { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
function error { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

function wait_mysql {
  info "Waiting for MySQL to be ready..."
  for i in {1..30}; do
    if mysqladmin ping --silent; then
      success "MySQL is ready."
      return 0
    fi
    sleep 2
  done
  error "MySQL not ready, exiting."
}

function mysql_exec {
  mysql -u root -e "$1"
}

if [ "$(id -u)" -ne 0 ]; then
  error "Run this script as root or with sudo."
fi

info "Updating system..."
apt-get update -y && apt-get upgrade -y

info "Installing dependencies..."
apt-get install -y software-properties-common curl unzip git mysql-server nginx nodejs npm php$PHP_VERSION php$PHP_VERSION-fpm php$PHP_VERSION-mysql php$PHP_VERSION-xml php$PHP_VERSION-mbstring php$PHP_VERSION-curl php$PHP_VERSION-zip php$PHP_VERSION-bcmath php$PHP_VERSION-tokenizer php$PHP_VERSION-common php$PHP_VERSION-gd php$PHP_VERSION-cli

if ! command -v composer &>/dev/null; then
  info "Installing Composer..."
  curl -sS https://getcomposer.org/installer | php
  mv composer.phar /usr/local/bin/composer
fi

success "Dependencies installed."

info "Starting MySQL service..."
service mysql start
wait_mysql

info "Creating MySQL database and user..."
mysql_exec "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql_exec "CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';"
mysql_exec "GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';"
mysql_exec "FLUSH PRIVILEGES;"
success "Database setup complete."

info "Creating fresh Laravel project in $APP_DIR ..."
if [ -d "$APP_DIR" ]; then
  info "$APP_DIR exists. Removing for clean install."
  rm -rf "$APP_DIR"
fi

composer create-project --prefer-dist laravel/laravel "$APP_DIR"

cd "$APP_DIR"

info "Updating .env with database credentials..."
sed -i "s/^DB_DATABASE=.*/DB_DATABASE=$DB_NAME/" .env
sed -i "s/^DB_USERNAME=.*/DB_USERNAME=$DB_USER/" .env
sed -i "s/^DB_PASSWORD=.*/DB_PASSWORD=$DB_PASS/" .env

info "Generating Laravel app key..."
php artisan key:generate

info "Running migrations..."
php artisan migrate --force

info "Creating admin user..."
php artisan tinker --execute="
\$userClass = config('auth.providers.users.model');
if (!\$userClass::where('email', '$ADMIN_EMAIL')->exists()) {
  \$user = new \$userClass();
  \$user->name = 'Admin';
  \$user->email = '$ADMIN_EMAIL';
  \$user->password = bcrypt('$ADMIN_PASS');
  \$user->save();
}"

info "Creating storage symlink..."
php artisan storage:link

info "Fixing permissions for storage and cache..."
chown -R www-data:www-data storage bootstrap/cache
chmod -R 775 storage bootstrap/cache

info "Clearing and caching config..."
php artisan config:clear
php artisan config:cache

info "Setting up frontend (Vue.js) ..."

# Laravel default with Vite uses package.json in root
if [ -f "package.json" ]; then
  npm install
  npm run build
else
  info "No package.json found. Skipping frontend build."
fi

info "Configuring Nginx..."

NGINX_FPM_SOCK="/run/php/php${PHP_VERSION}-fpm.sock"
if [ ! -S "$NGINX_FPM_SOCK" ]; then
  # Try alternative path
  NGINX_FPM_SOCK="/var/run/php/php${PHP_VERSION}-fpm.sock"
  if [ ! -S "$NGINX_FPM_SOCK" ]; then
    error "PHP-FPM socket not found at expected locations."
  fi
fi

cat > /etc/nginx/sites-available/magicalpanel <<EOL
server {
    listen $APP_PORT default_server;
    listen [::]:$APP_PORT default_server;

    server_name _;

    root $APP_DIR/public;
    index index.php index.html;

    access_log /var/log/nginx/magicalpanel_access.log;
    error_log /var/log/nginx/magicalpanel_error.log;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:$NGINX_FPM_SOCK;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOL

ln -sf /etc/nginx/sites-available/magicalpanel /etc/nginx/sites-enabled/

info "Testing Nginx config..."
nginx -t

info "Reloading Nginx..."
service nginx reload

info "Restarting PHP-FPM service..."
service php$PHP_VERSION-fpm restart

info "Setting permissions for Laravel directory..."
chown -R www-data:www-data "$APP_DIR"
find "$APP_DIR" -type d -exec chmod 755 {} \;
find "$APP_DIR" -type f -exec chmod 644 {} \;

success "Installation complete!"

echo
echo -e "${GREEN}You can access your panel at: http://YOUR_SERVER_IP${NC}"
echo -e "${GREEN}Admin email: $ADMIN_EMAIL${NC}"
echo -e "${GREEN}Admin password: $ADMIN_PASS${NC}"
echo

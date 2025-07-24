#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

echo "--- Running Jportal.com - Modular Deployment Script 3/3 (Deploy Django Application) ---"

# Secrets and VM_IP_ADDRESS passed from bootstrap script as environment variables
# DB_PASSWORD
# RADIUS_SHARED_SECRET
# DJANGO_SECRET_KEY
# VM_IP_ADDRESS

PROJECT_DIR="/home/$USER/jportal_project"
DJANGO_CORE_NAME="jportal_core"
DJANGO_APPS="portal admin_portal auth_mgmt" # Space-separated list of your Django app names

echo "Using VM IP Address: $VM_IP_ADDRESS"
echo "Project will be created in: $PROJECT_DIR (your home directory)"
echo ""

echo "--- Setting up Jportal.com Django Project ---"
# Create project directory and navigate into it
echo "Creating project directory $PROJECT_DIR..."
mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"

# Create .env file
echo "Creating .env file..."
cat <<EOF > .env
SECRET_KEY='$DJANGO_SECRET_KEY'
DEBUG=True
ALLOWED_HOSTS='localhost,127.0.0.1,$VM_IP_ADDRESS'

DB_NAME=jportal_db
DB_USER=jportal_user
DB_PASSWORD=$DB_PASSWORD
DB_HOST=172.17.0.1 # This is the Docker host's IP for containers to reach services on the VM's main network
DB_PORT=5432

RADIUS_HOST=172.17.0.1 # FreeRADIUS is on the VM itself, Docker app connects to VM's loopback
RADIUS_AUTH_PORT=1812
RADIUS_COA_PORT=3799
RADIUS_SHARED_SECRET=$RADIUS_SHARED_SECRET
EOF
echo ".env file created."

# Create requirements.txt
echo "Creating requirements.txt..."
cat <<EOF > requirements.txt
Django==5.0.*
djangorestframework==3.15.*
psycopg2-binary==2.9.*
python-dotenv==1.0.*
gunicorn==22.0.*
EOF
echo "requirements.txt created."

# Create Dockerfile
echo "Creating Dockerfile..."
cat <<EOF > Dockerfile
FROM python:3.10-slim-bullseye
WORKDIR /app

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    libpq-dev \
    gcc \
    python3-dev \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt /app/
RUN pip install --no-cache-dir -r requirements.txt

# --- Copy Django project structure to /app directly ---
COPY manage.py /app/manage.py
COPY ${DJANGO_CORE_NAME} /app/${DJANGO_CORE_NAME} # Copy the core project
COPY apps /app/apps # Copy the apps directory
# --- End of Django project structure copy ---
ENV PYTHONUNBUFFERED 1
EXPOSE 8000
CMD ["sh", "-c", "python manage.py runserver 0.0.0.0:8000"]
EOF
echo "Dockerfile created."

# Create Nginx configuration
echo "Creating nginx/nginx.conf..."
mkdir -p nginx
cat <<EOF > nginx/nginx.conf
worker_processes 1;
events { worker_connections 1024; }
http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    sendfile on;
    keepalive_timeout 65;
    upstream django {
        server django:8000;
    }
    server {
        listen 80;
        server_name localhost 127.0.0.1 ${VM_IP_ADDRESS};
        location /static/ {
            alias /app/static/;
        }
        location /media/ {
            alias /app/media/;
        }
        location / {
            proxy_pass http://django;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header Host \$host;
            proxy_redirect off;
        }
    }
}
EOF
echo "nginx/nginx.conf created."

# Create docker-compose.yml
echo "Creating docker-compose.yml..."
cat <<EOF > docker-compose.yml
version: '3.8'

services:
  django:
    image: python:3.10-slim-bullseye
    working_dir: /app
    volumes:
      - "$PROJECT_DIR/manage.py:/app/manage.py"
      - "$PROJECT_DIR/${DJANGO_CORE_NAME}:/app/${DJANGO_CORE_NAME}"
      - "$PROJECT_DIR/apps:/app/apps"
      - "$PROJECT_DIR/requirements.txt:/app/requirements.txt"
      - "$PROJECT_DIR/.env:/app/.env"
      - "$PROJECT_DIR/static:/app/static"
      - "$PROJECT_DIR/media:/app/media"
    ports:
      - "8000:8000"
    depends_on:
      - nginx
    command: ["sh", "-c", "python manage.py runserver 0.0.0.0:8000"]

  nginx:
    image: nginx:latest
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./static:/app/static:ro
      - ./media:/app/media:ro
    ports:
      - "80:80"
    depends_on:
      - django

EOF
echo "docker-compose.yml created."

# Create Django project structure (NOW DIRECTLY IN PROJECT_DIR)
echo "Creating Django project structure directly in $PROJECT_DIR..."
cd "$PROJECT_DIR"

# Use temporary virtual environment for django-admin commands
echo "Setting up temporary Python virtual environment..."
python3 -m venv .venv_temp
source .venv_temp/bin/activate
pip install Django # Install Django in temp venv

echo "Starting Django project '${DJANGO_CORE_NAME}'..."
# Create core project and manage.py directly in $PROJECT_DIR
django-admin startproject "$DJANGO_CORE_NAME" .

# Create Django apps directly in $PROJECT_DIR
for app in $DJANGO_APPS; do
    echo "Creating Django app: $app"
    python manage.py startapp "$app"
done

deactivate # Deactivate temp venv
rm -rf .venv_temp # Clean up temp venv

echo "Django project structure created directly in $PROJECT_DIR."

# Adjust settings.py
echo "Adjusting settings.py..."
SETTINGS_FILE="${DJANGO_CORE_NAME}/settings.py"
# Add environment variable loading
sed -i "1s/^/import os\nfrom dotenv import load_dotenv\n\nload_dotenv()\n\n/" "$SETTINGS_FILE"
# Update SECRET_KEY, DEBUG, ALLOWED_HOSTS using os.getenv
sed -i "s/^SECRET_KEY = .*/SECRET_KEY = os.getenv('SECRET_KEY')/" "$SETTINGS_FILE"
sed -i "s/^DEBUG = .*/DEBUG = os.getenv('DEBUG', 'False') == 'True'/" "$SETTINGS_FILE"
sed -i "s/^ALLOWED_HOSTS = .*/ALLOWED_HOSTS = os.getenv('ALLOWED_HOSTS', '').split(',')/" "$SETTINGS_FILE"
# Update DATABASES configuration
sed -i "/'ENGINE': 'django.db.backends.sqlite3',/c\
        'ENGINE': 'django.db.backends.postgresql',\n\
        'NAME': os.getenv('DB_NAME'),\n\
        'USER': os.getenv('DB_USER'),\n\
        'PASSWORD': os.getenv('DB_PASSWORD'),\n\
        'HOST': os.getenv('DB_HOST'),\n\
        'PORT': os.getenv('DB_PORT')," "$SETTINGS_FILE"
# Add STATIC_ROOT and MEDIA_ROOT
cat <<EOF >> "$SETTINGS_FILE"

# Static files (CSS, JavaScript, Images)
# https://docs.djangoproject.com/en/5.0/howto/static-files/
STATIC_URL = 'static/'
STATIC_ROOT = BASE_DIR / 'static'

# Media files (user uploaded content)
MEDIA_URL = 'media/'
MEDIA_ROOT = BASE_DIR / 'media'
EOF

# Add apps to INSTALLED_APPS
echo "Adding Django apps to INSTALLED_APPS..."
# Find the line for 'django.contrib.staticfiles' and insert after it
APPS_TO_ADD="    'rest_framework',\n"
for app in $DJANGO_APPS; do
    APPS_TO_ADD+="    '${app}',\n"
done
sed -i "/'django.contrib.staticfiles',/a\\
${APPS_TO_ADD}" "$SETTINGS_FILE"

# Adjust main urls.py
echo "Adjusting main urls.py..."
MAIN_URLS_FILE="${DJANGO_CORE_NAME}/urls.py"
sed -i "/from django.urls import path/a from django.urls import include\nfrom django.conf import settings\nfrom django.conf.urls.static import static" "$MAIN_URLS_FILE"
# Ensure the order of include paths. Putting more specific ones first can sometimes prevent conflicts.
sed -i "/urlpatterns = \[/a \    path('admin-portal/', include('admin_portal.urls')),\n    path('auth-mgmt/', include('auth_mgmt.urls')),\n    path('portal/', include('portal.urls'))," "$MAIN_URLS_FILE"
cat <<EOF >> "$MAIN_URLS_FILE"

if settings.DEBUG:
    urlpatterns += static(settings.STATIC_URL, document_root=settings.STATIC_ROOT)
    urlpatterns += static(settings.MEDIA_URL, document_root=settings.MEDIA_ROOT)
EOF
echo "Main urls.py adjusted."

# Create basic urls.py and views.py for each app (now directly in project root)
echo "Creating basic app URLs and Views..."
for app in $DJANGO_APPS; do
    APP_DIR="$app"
    APP_URLS_FILE="${APP_DIR}/urls.py"
    APP_VIEWS_FILE="${APP_DIR}/views.py"

    # Ensure app directory exists in root
    mkdir -p "$APP_DIR"
    
    cat <<EOF > "$APP_URLS_FILE"
from django.urls import path
from . import views

urlpatterns = [
    path('', views.index, name='index'), # Placeholder view
]
EOF

    cat <<EOF > "$APP_VIEWS_FILE"
from django.http import HttpResponse

def index(request):
    return HttpResponse("Hello from Jportal ${app}!")
EOF
done
echo "Basic app URLs and Views created."


echo "--- Step 6: Deploying Jportal.com with Docker Compose ---"
# Create static and media directories that Docker will mount
echo "Creating static and media directories..."
mkdir -p static media

# Run Django database migrations
echo "Running Django database migrations..."
docker-compose run --rm django python manage.py makemigrations
docker-compose run --rm django python manage.py migrate

# Collect Django static files
echo "Collecting Django static files..."
docker-compose run --rm django python manage.py collectstatic --noinput

# Create Django Superuser
echo "Creating Django Superuser. Follow the prompts..."
docker-compose run --rm django python manage.py createsuperuser

# Start all services
echo "Starting Jportal.com services with Docker Compose in detached mode..."
# No --build here as image is not built from this script anymore, it's a base image
docker-compose up -d

echo ""
echo "█████████████████████████████████████████████████████████████"
echo "██                                                         ██"
echo "██    Jportal.com VM Deployment Complete!                  ██"
echo "██                                                         ██"
echo "█████████████████████████████████████████████████████████████"
echo ""
echo "You can now access your Jportal.com development environment:"
echo "- **Django Admin:** http://${VM_IP_ADDRESS}/admin/"
echo "- **Jportal Portal (placeholder):** http://${VM_IP_ADDRESS}/portal/"
echo "- **Jportal Admin Portal (placeholder):** http://${VM_IP_ADDRESS}/admin-portal/"
echo "- **Jportal Auth Management (placeholder):** http://${VM_IP_ADDRESS}/auth-mgmt/"
echo ""
echo "Remember your Django Superuser credentials and the passwords you set."
echo "If you encounter any issues, ensure you've re-logged into the VM via SSH after adding yourself to the 'docker' group (if that was prompted)."
echo "You can check service status with 'docker-compose ps' or 'sudo systemctl status freeradius'."
echo "To stop services: 'docker-compose down' (from $PROJECT_DIR)"
echo "To restart services: 'docker-compose restart' (from $PROJECT_DIR)"

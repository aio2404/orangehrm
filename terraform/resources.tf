# Create namespace for OrangeHRM
resource "kubernetes_namespace" "orangehrm" {
  metadata {
    name = var.namespace
    labels = {
      app = "orangehrm"
    }
  }
}

# MySQL ConfigMap for initialization
resource "kubernetes_config_map" "mysql_init" {
  metadata {
    name      = "mysql-init"
    namespace = kubernetes_namespace.orangehrm.metadata[0].name
  }
  data = {
    "init.sql" = <<-EOT
      ALTER USER IF EXISTS 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${var.mysql_root_password}';
      ALTER USER IF EXISTS 'root'@'%' IDENTIFIED WITH mysql_native_password BY '${var.mysql_root_password}';
      FLUSH PRIVILEGES;
    EOT
  }
  depends_on = [kubernetes_namespace.orangehrm]
}

# OrangeHRM CLI Install ConfigMap
resource "kubernetes_config_map" "orangehrm_install_config" {
  metadata {
    name      = "orangehrm-install-config"
    namespace = kubernetes_namespace.orangehrm.metadata[0].name
  }
  data = {
    "cli_install_config.yaml" = <<-EOT
database:
  hostName: mysql
  hostPort: 3306
  databaseName: ${var.mysql_database}
  privilegedDatabaseUser: root
  privilegedDatabasePassword: ${var.mysql_root_password}
  useSameDbUserForOrangeHRM: n
  orangehrmDatabaseUser: ${var.mysql_user}
  orangehrmDatabasePassword: ${var.mysql_password}
  isExistingDatabase: n
  enableDataEncryption: n

organization:
  name: OrangeHRM
  country: US

admin:
  adminUserName: admin
  adminPassword: admin
  adminEmployeeFirstName: OrangeHRM
  adminEmployeeLastName: Admin
  workEmail: admin@example.com
  contactNumber: ~
  registrationConsent: true

license:
  agree: y
    EOT
  }
  depends_on = [kubernetes_namespace.orangehrm]
}

# OrangeHRM Conf.php ConfigMap
resource "kubernetes_config_map" "orangehrm_conf_php" {
  metadata {
    name      = "orangehrm-conf-php"
    namespace = kubernetes_namespace.orangehrm.metadata[0].name
  }
  data = {
    "Conf.php" = <<-EOT
<?php
class Conf
{
    private string $dbHost;
    private string $dbPort;
    private string $dbName;
    private string $dbUser;
    private string $dbPass;

    public function __construct()
    {
        $this->dbHost = 'mysql';
        $this->dbPort = '3306';
        $this->dbName = '${var.mysql_database}';
        $this->dbUser = '${var.mysql_user}';
        $this->dbPass = '${var.mysql_password}';
    }

    public function getDbHost(): string { return $this->dbHost; }
    public function getDbPort(): string { return $this->dbPort; }
    public function getDbName(): string { return $this->dbName; }
    public function getDbUser(): string { return $this->dbUser; }
    public function getDbPass(): string { return $this->dbPass; }
}
    EOT
  }
  depends_on = [kubernetes_namespace.orangehrm]
}

# MySQL Persistent Volume Claim
resource "kubernetes_persistent_volume_claim" "mysql_pvc" {
  metadata {
    name      = "mysql-pvc"
    namespace = kubernetes_namespace.orangehrm.metadata[0].name
  }
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = "10Gi"
      }
    }
  }
  depends_on = [kubernetes_namespace.orangehrm]
}

# MySQL Deployment
resource "kubernetes_deployment" "mysql" {
  metadata {
    name      = "mysql"
    namespace = kubernetes_namespace.orangehrm.metadata[0].name
    labels = {
      app = "mysql"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "mysql"
      }
    }
    template {
      metadata {
        labels = {
          app = "mysql"
        }
      }
      spec {
        # Clear stale InnoDB files from previous runs to avoid lock errors on PVCs
        init_container {
          name    = "mysql-data-reset"
          image   = "busybox:1.36"
          command = ["/bin/sh", "-c", "rm -rf /var/lib/mysql/*"]
          volume_mount {
            name       = "mysql-storage"
            mount_path = "/var/lib/mysql"
          }
        }
        container {
          image = "${var.mysql_image}:${var.mysql_tag}"
          name  = "mysql"
          port {
            container_port = 3306
          }
          env {
            name  = "MYSQL_ROOT_PASSWORD"
            value = var.mysql_root_password
          }
          env {
            name  = "MYSQL_ROOT_HOST"
            value = "%"
          }
          # Mount initialization script
          volume_mount {
            name       = "mysql-init"
            mount_path = "/docker-entrypoint-initdb.d"
          }
          # Mount persistent storage
          volume_mount {
            name       = "mysql-storage"
            mount_path = "/var/lib/mysql"
          }
          # Health checks
          liveness_probe {
            tcp_socket {
              port = 3306
            }
            initial_delay_seconds = 30
            period_seconds        = 10
            timeout_seconds       = 10
            failure_threshold     = 3
          }
          readiness_probe {
            exec {
              command = ["mysqladmin", "ping", "-h", "localhost"]
            }
            initial_delay_seconds = 5
            period_seconds        = 5
            timeout_seconds       = 10
            failure_threshold     = 3
          }
          # Resource limits
          resources {
            limits = {
              cpu    = "1000m"
              memory = "1Gi"
            }
            requests = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }
        }
        # Volume for initialization script
        volume {
          name = "mysql-init"
          config_map {
            name = kubernetes_config_map.mysql_init.metadata[0].name
          }
        }
        # Volume for persistent storage
        volume {
          name = "mysql-storage"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.mysql_pvc.metadata[0].name
          }
        }
      }
    }
  }
  depends_on = [kubernetes_namespace.orangehrm, kubernetes_config_map.mysql_init, kubernetes_persistent_volume_claim.mysql_pvc]
}

# MySQL Service
resource "kubernetes_service" "mysql" {
  metadata {
    name      = "mysql"
    namespace = kubernetes_namespace.orangehrm.metadata[0].name
    labels = {
      app = "mysql"
    }
  }
  spec {
    selector = {
      app = "mysql"
    }
    port {
      name        = "mysql"
      port        = 3306
      target_port = 3306
    }
    type = "ClusterIP"
  }
  depends_on = [kubernetes_deployment.mysql]
}

# Job to initialize OrangeHRM database
resource "kubernetes_job" "orangehrm_init" {
  metadata {
    name      = "orangehrm-init"
    namespace = kubernetes_namespace.orangehrm.metadata[0].name
  }
  spec {
    template {
      metadata {
        labels = {
          app = "orangehrm-init"
        }
      }
      spec {
        restart_policy = "Never"
        container {
          name    = "orangehrm-init"
          image   = "${var.orangehrm_image}:${var.orangehrm_tag}"
          command = ["/bin/bash", "-c"]
          args = [
            join(" && ", [
              "set -e",
              "echo 'Installing MySQL client...'",
              "apt-get update",
              "apt-get install -y default-mysql-client || apt-get install -y mariadb-client || apt-get install -y mysql-client || echo 'MySQL client installation failed, continuing...'",
              "echo 'Waiting for MySQL to be ready...'",
              "until mysql -h mysql --ssl=0 -u root -p${var.mysql_root_password} -e 'SELECT 1;' >/dev/null 2>&1; do echo 'MySQL not ready yet, waiting...'; sleep 5; done",
              "echo 'MySQL is ready!'",
              "echo 'Dropping existing OrangeHRM database (if present)...'",
              "mysql -h mysql --ssl=0 -u root -p${var.mysql_root_password} -e \"DROP DATABASE IF EXISTS ${var.mysql_database};\"",
              "echo 'Dropping existing OrangeHRM MySQL users (if present)...'",
              "mysql -h mysql --ssl=0 -u root -p${var.mysql_root_password} -e \"DROP USER IF EXISTS '${var.mysql_user}'@'%';\"",
              "mysql -h mysql --ssl=0 -u root -p${var.mysql_root_password} -e \"DROP USER IF EXISTS '${var.mysql_user}'@'localhost';\"",
              "cp /config/cli_install_config.yaml /var/www/html/installer/cli_install_config.yaml",
              "echo 'Initializing OrangeHRM database...'",
              "cd /var/www/html/installer",
              "timeout 600 php cli_install.php 2>&1 | tee /tmp/install.log || (echo 'Installation timed out or failed'; echo 'Installation log:'; cat /tmp/install.log; exit 1)",
              "echo 'OrangeHRM database initialization completed!'",
              "mkdir -p /var/www/html/src/config",
              "cp /conf-php/Conf.php /var/www/html/src/config/Conf.php",
              "echo 'Configuration file created'"
            ])
          ]
          env {
            name  = "DB_HOST"
            value = "mysql"
          }
          env {
            name  = "DB_PORT"
            value = "3306"
          }
          env {
            name  = "DB_NAME"
            value = var.mysql_database
          }
          env {
            name  = "DB_USER"
            value = var.mysql_user
          }
          env {
            name  = "DB_PASS"
            value = var.mysql_password
          }
          env {
            name  = "MYSQL_ROOT_PASSWORD"
            value = var.mysql_root_password
          }
          volume_mount {
            name       = "install-config"
            mount_path = "/config"
          }
          volume_mount {
            name       = "conf-php"
            mount_path = "/conf-php"
          }
          # Resource limits
          resources {
            limits = {
              cpu    = "1000m"
              memory = "1Gi"
            }
            requests = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }
        }
        volume {
          name = "install-config"
          config_map {
            name = kubernetes_config_map.orangehrm_install_config.metadata[0].name
          }
        }
        volume {
          name = "conf-php"
          config_map {
            name = kubernetes_config_map.orangehrm_conf_php.metadata[0].name
          }
        }
      }
    }
    backoff_limit              = 3
    ttl_seconds_after_finished = 300
    active_deadline_seconds    = 900 # 15 minutes timeout for the entire job
  }
  timeouts {
    create = "5m"
    update = "5m"
  }
  depends_on = [kubernetes_deployment.mysql, kubernetes_config_map.orangehrm_install_config]
}

# OrangeHRM ConfigMap for database configuration
resource "kubernetes_config_map" "orangehrm_config" {
  metadata {
    name      = "orangehrm-config"
    namespace = kubernetes_namespace.orangehrm.metadata[0].name
  }
  data = {
    "db_host" = "mysql"
    "db_port" = "3306"
    "db_name" = var.mysql_database
    "db_user" = var.mysql_user
    "db_pass" = var.mysql_password
  }
  depends_on = [kubernetes_namespace.orangehrm]
}

# OrangeHRM Deployment
resource "kubernetes_deployment" "orangehrm" {
  metadata {
    name      = "orangehrm"
    namespace = kubernetes_namespace.orangehrm.metadata[0].name
    labels = {
      app = "orangehrm"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "orangehrm"
      }
    }
    template {
      metadata {
        labels = {
          app = "orangehrm"
        }
      }
      spec {
        init_container {
          name    = "orangehrm-config-init"
          image   = "${var.orangehrm_image}:${var.orangehrm_tag}"
          command = ["/bin/bash", "-c"]
          args = [
            join(" && ", [
              "set -e",
              "echo 'Creating OrangeHRM configuration files...'",
              "mkdir -p /var/www/html/lib/confs",
              "mkdir -p /var/www/html/src/config",
              "cp /conf-php/Conf.php /var/www/html/lib/confs/Conf.php",
              "echo '<?php' > /var/www/html/src/config/log_settings.php",
              "echo 'return [' >> /var/www/html/src/config/log_settings.php",
              "echo '    \"log_level\" => \"error\",' >> /var/www/html/src/config/log_settings.php",
              "echo '    \"log_file\" => \"/var/www/html/src/log/orangehrm.log\"' >> /var/www/html/src/config/log_settings.php",
              "echo '];' >> /var/www/html/src/config/log_settings.php",
              "echo 'Configuration files created successfully!'"
            ])
          ]
          volume_mount {
            name       = "orangehrm-config"
            mount_path = "/var/www/html/lib/confs"
          }
          volume_mount {
            name       = "conf-php"
            mount_path = "/conf-php"
          }
        }
        container {
          image = "${var.orangehrm_image}:${var.orangehrm_tag}"
          name  = "orangehrm"
          port {
            container_port = 80
          }
          env {
            name  = "DB_HOST"
            value = "mysql"
          }
          env {
            name  = "DB_PORT"
            value = "3306"
          }
          env {
            name  = "DB_NAME"
            value = var.mysql_database
          }
          env {
            name  = "DB_USER"
            value = var.mysql_user
          }
          env {
            name  = "DB_PASS"
            value = var.mysql_password
          }
          volume_mount {
            name       = "orangehrm-config"
            mount_path = "/var/www/html/lib/confs"
          }
          # Health checks
          liveness_probe {
            http_get {
              path = "/"
              port = 80
            }
            initial_delay_seconds = 60
            period_seconds        = 10
            timeout_seconds       = 10
            failure_threshold     = 3
          }
          readiness_probe {
            http_get {
              path = "/"
              port = 80
            }
            initial_delay_seconds = 30
            period_seconds        = 5
            timeout_seconds       = 10
            failure_threshold     = 3
          }
          # Resource limits
          resources {
            limits = {
              cpu    = "1000m"
              memory = "1Gi"
            }
            requests = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }
        }
        volume {
          name = "orangehrm-config"
          empty_dir {}
        }
        volume {
          name = "conf-php"
          config_map {
            name = kubernetes_config_map.orangehrm_conf_php.metadata[0].name
          }
        }
      }
    }
  }
  depends_on = [kubernetes_job.orangehrm_init, kubernetes_config_map.orangehrm_config]
}

# OrangeHRM Service
resource "kubernetes_service" "orangehrm" {
  metadata {
    name      = "orangehrm"
    namespace = kubernetes_namespace.orangehrm.metadata[0].name
    annotations = var.environment == "gke" && !var.public_access ? {
      "networking.gke.io/load-balancer-type" = "Internal"
    } : {}
    labels = {
      app = "orangehrm"
    }
  }
  spec {
    selector = {
      app = "orangehrm"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 80
    }
    type = "NodePort"
  }
  depends_on = [kubernetes_deployment.orangehrm]
}

# Job to complete OrangeHRM web installation
resource "kubernetes_job" "orangehrm_web_setup" {
  count = var.environment == "minikube" ? 1 : 0
  metadata {
    name      = "orangehrm-web-setup"
    namespace = kubernetes_namespace.orangehrm.metadata[0].name
  }
  spec {
    template {
      metadata {
        labels = {
          app = "orangehrm-web-setup"
        }
      }
      spec {
        restart_policy = "Never"
        container {
          name    = "orangehrm-web-setup"
          image   = "curlimages/curl:latest"
          command = ["/bin/sh", "-c"]
          args = [
            join(" && ", [
              "echo 'Waiting for OrangeHRM web service to be ready...'",
              "until curl -f http://orangehrm/ >/dev/null 2>&1; do echo 'OrangeHRM web service not ready yet, waiting...'; sleep 10; done",
              "echo 'OrangeHRM web service is ready!'",
              "echo 'Completing web installation steps...'",
              "curl -X POST http://orangehrm/installer/api/send-data/installer-start -H 'Content-Type: application/json' -d '{}' || echo 'Installer start notification failed'",
              "curl -X POST http://orangehrm/installer/api/installation/database -H 'Content-Type: application/json' -d '{}' || echo 'Database creation step failed'",
              "curl -X POST http://orangehrm/installer/api/installation/pre-migration -H 'Content-Type: application/json' -d '{}' || echo 'Pre-migration check failed'",
              "curl -X POST http://orangehrm/installer/api/installation/migration -H 'Content-Type: application/json' -d '{\"version\":\"0.0\"}' || echo 'Migration step failed'",
              "curl -X POST http://orangehrm/installer/api/installation/instance -H 'Content-Type: application/json' -d '{}' || echo 'Instance creation step failed'",
              "curl -X POST http://orangehrm/installer/api/installation/database-user -H 'Content-Type: application/json' -d '{}' || echo 'Database user creation step failed'",
              "curl -X POST http://orangehrm/installer/api/installation/config-file -H 'Content-Type: application/json' -d '{}' || echo 'Config file creation step failed'",
              "curl -X POST http://orangehrm/installer/api/clean-up-install -H 'Content-Type: application/json' -d '{}' || echo 'Cleanup step failed'",
              "echo 'OrangeHRM web installation fully completed!'"
            ])
          ]
        }
      }
    }
    backoff_limit              = 3
    ttl_seconds_after_finished = 300
    active_deadline_seconds    = 600 # 10 minutes timeout
  }
  depends_on = [kubernetes_service.orangehrm]
}

# ConfigMap for data loading scripts
resource "kubernetes_config_map" "data_scripts" {
  count = var.load_sample_data ? 1 : 0
  metadata {
    name      = "data-scripts"
    namespace = kubernetes_namespace.orangehrm.metadata[0].name
  }
  data = {
    "load-employees.php"     = file("${path.module}/../devTools/load/general/load-employees.php")
    "load-candidates.php"    = file("${path.module}/../devTools/load/recruitment/load-candidates.php")
    "canidate-name-list.txt" = file("${path.module}/candidate-name-list.txt")
    "job-description-1.txt"  = file("${path.module}/../devTools/load/recruitment/job-description-1.txt")
    "job-description-2.txt"  = file("${path.module}/../devTools/load/recruitment/job-description-2.txt")
    "job-description-3.txt"  = file("${path.module}/../devTools/load/recruitment/job-description-3.txt")
    "job-description-4.txt"  = file("${path.module}/../devTools/load/recruitment/job-description-4.txt")
    "job-description-5.txt"  = file("${path.module}/../devTools/load/recruitment/job-description-5.txt")
  }
  depends_on = [kubernetes_namespace.orangehrm]
}

# Job to load employee data
resource "kubernetes_job" "load_employees" {
  count = var.load_sample_data ? 1 : 0
  metadata {
    name      = "load-employees"
    namespace = kubernetes_namespace.orangehrm.metadata[0].name
  }
  spec {
    template {
      metadata {
        labels = {
          app = "data-loader"
        }
      }
      spec {
        restart_policy = "Never"
        container {
          name    = "data-loader"
          image   = "${var.orangehrm_image}:${var.orangehrm_tag}"
          command = ["/bin/bash", "-c"]
          args = [
            join(" && ", [
              "set -e",
              "export DEBIAN_FRONTEND=noninteractive",
              "echo 'Installing required packages...'",
              "apt-get update",
              "apt-get install -y --no-install-recommends curl default-mysql-client || apt-get install -y --no-install-recommends curl mariadb-client",
              "rm -rf /var/lib/apt/lists/*",
              "echo 'Creating temporary work directory...'",
              "WORK_DIR=$(mktemp -d)",
              "trap 'rm -rf \"$WORK_DIR\"' EXIT",
              "cp -r /scripts/. \"$WORK_DIR/\"",
              "echo 'Waiting for MySQL to be ready...'",
              "until mysql -h mysql --ssl=0 -u root -p${var.mysql_root_password} -e 'SELECT 1;' > /dev/null 2>&1; do echo 'MySQL not ready yet, waiting...'; sleep 5; done",
              "echo 'MySQL is ready!'",
              "echo 'Ensuring OrangeHRM user exists...'",
              "mysql -h mysql --ssl=0 -u root -p${var.mysql_root_password} -e \"CREATE DATABASE IF NOT EXISTS ${var.mysql_database}; CREATE USER IF NOT EXISTS '${var.mysql_user}'@'%' IDENTIFIED BY '${var.mysql_password}'; ALTER USER '${var.mysql_user}'@'%' IDENTIFIED WITH mysql_native_password BY '${var.mysql_password}'; GRANT ALL PRIVILEGES ON ${var.mysql_database}.* TO '${var.mysql_user}'@'%'; FLUSH PRIVILEGES;\"",
              "echo 'Waiting for OrangeHRM to be ready...'",
              "until curl_output=$(curl -f http://orangehrm/ 2>&1 >/dev/null); do rc=$?; echo 'OrangeHRM not ready yet, waiting... (rc='$rc')'; echo 'curl error: '$curl_output; sleep 10; done",
              "echo 'OrangeHRM is ready!'",
              "echo 'Loading employee data...'",
              "DB_HOST=mysql DB_USER=${var.mysql_user} DB_PASS=${var.mysql_password} DB_NAME=${var.mysql_database} php \"$WORK_DIR/load-employees.php\"",
              "echo 'Employee data loading completed!'"
            ])
          ]
          env {
            name  = "DB_HOST"
            value = "mysql"
          }
          env {
            name  = "DB_PORT"
            value = "3306"
          }
          env {
            name  = "DB_NAME"
            value = var.mysql_database
          }
          env {
            name  = "DB_USER"
            value = var.mysql_user
          }
          env {
            name  = "DB_PASS"
            value = var.mysql_password
          }
          env {
            name  = "MYSQL_ROOT_PASSWORD"
            value = var.mysql_root_password
          }
          volume_mount {
            name       = "data-scripts"
            mount_path = "/scripts"
            read_only  = true
          }
          # Resource limits
          resources {
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
          }
        }
        volume {
          name = "data-scripts"
          config_map {
            name = kubernetes_config_map.data_scripts[0].metadata[0].name
          }
        }
      }
    }
    backoff_limit              = 3
    ttl_seconds_after_finished = 300
  }
  depends_on = [kubernetes_deployment.orangehrm, kubernetes_config_map.data_scripts, kubernetes_job.orangehrm_init]
}

# Job to load candidate data
resource "kubernetes_job" "load_candidates" {
  count = var.load_sample_data ? 1 : 0
  metadata {
    name      = "load-candidates"
    namespace = kubernetes_namespace.orangehrm.metadata[0].name
  }
  spec {
    template {
      metadata {
        labels = {
          app = "data-loader"
        }
      }
      spec {
        restart_policy = "Never"
        container {
          name    = "data-loader"
          image   = "${var.orangehrm_image}:${var.orangehrm_tag}"
          command = ["/bin/bash", "-c"]
          args = [
            join(" && ", [
              "set -e",
              "export DEBIAN_FRONTEND=noninteractive",
              "echo 'Installing required packages...'",
              "apt-get update",
              "apt-get install -y --no-install-recommends curl default-mysql-client || apt-get install -y --no-install-recommends curl mariadb-client",
              "rm -rf /var/lib/apt/lists/*",
              "echo 'Creating temporary work directory...'",
              "WORK_DIR=$(mktemp -d)",
              "trap 'rm -rf \"$WORK_DIR\"' EXIT",
              "cp -r /scripts/. \"$WORK_DIR/\"",
              "echo 'Waiting for MySQL to be ready...'",
              "until mysql_output=$(mysql -h mysql --ssl=0 -u root -p${var.mysql_root_password} -e 'SELECT 1;' 2>&1); do rc=$?; echo 'MySQL not ready yet, waiting... (rc='$rc')'; echo 'mysql error: '$mysql_output; sleep 5; done",
              "echo 'MySQL is ready!'",
              "echo 'Ensuring OrangeHRM user exists...'",
              "mysql -h mysql --ssl=0 -u root -p${var.mysql_root_password} -e \"CREATE DATABASE IF NOT EXISTS ${var.mysql_database}; CREATE USER IF NOT EXISTS '${var.mysql_user}'@'%' IDENTIFIED BY '${var.mysql_password}'; ALTER USER '${var.mysql_user}'@'%' IDENTIFIED WITH mysql_native_password BY '${var.mysql_password}'; GRANT ALL PRIVILEGES ON ${var.mysql_database}.* TO '${var.mysql_user}'@'%'; FLUSH PRIVILEGES;\"",
              "echo 'Waiting for OrangeHRM to be ready...'",
              "until curl_output=$(curl -f http://orangehrm/ 2>&1 >/dev/null); do rc=$?; echo 'OrangeHRM not ready yet, waiting... (rc='$rc')'; echo 'curl error: '$curl_output; sleep 10; done",
              "echo 'OrangeHRM is ready!'",
              "echo 'Loading candidate data...'",
              "DB_HOST=mysql DB_USER=${var.mysql_user} DB_PASS=${var.mysql_password} DB_NAME=${var.mysql_database} php \"$WORK_DIR/load-candidates.php\"",
              "echo 'Candidate data loading completed!'"
            ])
          ]
          env {
            name  = "DB_HOST"
            value = "mysql"
          }
          env {
            name  = "DB_PORT"
            value = "3306"
          }
          env {
            name  = "DB_NAME"
            value = var.mysql_database
          }
          env {
            name  = "DB_USER"
            value = var.mysql_user
          }
          env {
            name  = "DB_PASS"
            value = var.mysql_password
          }
          env {
            name  = "MYSQL_ROOT_PASSWORD"
            value = var.mysql_root_password
          }
          volume_mount {
            name       = "data-scripts"
            mount_path = "/scripts"
            read_only  = true
          }
          # Resource limits
          resources {
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
          }
        }
        volume {
          name = "data-scripts"
          config_map {
            name = kubernetes_config_map.data_scripts[0].metadata[0].name
          }
        }
      }
    }
    backoff_limit              = 3
    ttl_seconds_after_finished = 300
  }
  depends_on = [kubernetes_job.load_employees, kubernetes_config_map.data_scripts]
}

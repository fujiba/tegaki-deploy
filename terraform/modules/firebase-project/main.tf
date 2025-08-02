terraform {
  required_providers {
    google-beta = {
      source = "hashicorp/google-beta"
      configuration_aliases = [ google-beta.no_user_project_override ]
    }
    random = {
      source = "hashicorp/random"
      version = "~> 3.0"
    }
    time = {
      source = "hashicorp/time"
    }
  }
}

# プロジェクトID用のランダムなサフィックスを生成
resource "random_id" "project_suffix" {
  byte_length = 4 
}

resource "google_project" "default" {
  provider = google-beta.no_user_project_override
  project_id = "${var.project_id_prefix}-${random_id.project_suffix.hex}"
  name            = var.project_name
  billing_account = var.billing_account
  deletion_policy = "DELETE"

  labels = {
    "firebase" = "enabled"
  }
}

locals {
  services4withfunctions = [
    "cloudbilling.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "firebase.googleapis.com",
    "cloudbuild.googleapis.com",
    "secretmanager.googleapis.com",
    # Enabling the ServiceUsage API allows the new project to be quota checked from now on.
    "serviceusage.googleapis.com",
    "drive.googleapis.com",
    "cloudtasks.googleapis.com"
  ]
}

resource "google_project_service" "default" {
  provider = google-beta.no_user_project_override
  project  = google_project.default.project_id
  for_each = toset(local.services4withfunctions)
  service = each.key

  # Don't disable the service if the resource block is removed by accident.
  disable_on_destroy = false

  depends_on = [time_sleep.wait_60_seconds]
}

resource "google_firebase_project" "default" {
  provider = google-beta
  project  = google_project.default.project_id

  depends_on = [
    google_project_service.default,
  ]
}

resource "time_sleep" "wait_60_seconds" {
  depends_on = [google_project.default]

  create_duration = "60s"
}

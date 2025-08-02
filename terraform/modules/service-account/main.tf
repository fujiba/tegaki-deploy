
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
    }
  }
}

resource "google_service_account" "service_account" {
  project      = var.project_id
  account_id   = "deploy"
  display_name = "Deploy user"
}

resource "google_project_iam_member" "service_account_user" {
  project = var.project_id
  role    = "roles/iam.serviceAccountUser"
  member  = "serviceAccount:${google_service_account.service_account.email}"
}

resource "google_project_iam_member" "apikeys_viewer" {
  project = var.project_id
  role    = "roles/serviceusage.apiKeysViewer"
  member  = "serviceAccount:${google_service_account.service_account.email}"
}

resource "google_project_iam_member" "firebaserules_system" {
  project = var.project_id
  role    = "roles/firebaserules.system"
  member  = "serviceAccount:${google_service_account.service_account.email}"
}

resource "google_project_iam_member" "firebasehosting_admin" {
  project = var.project_id
  role    = "roles/firebasehosting.admin"
  member  = "serviceAccount:${google_service_account.service_account.email}"
}

resource "google_project_iam_member" "serviceusage_admin" {
  project = var.project_id
  role    = "roles/serviceusage.serviceUsageAdmin" # Add role to enable APIs
  member  = "serviceAccount:${google_service_account.service_account.email}"
}

resource "google_project_iam_member" "cloudfunctions_admin" {
  project = var.project_id
  role    = "roles/cloudfunctions.admin"
  member  = "serviceAccount:${google_service_account.service_account.email}"
}

resource "google_project_iam_member" "secretmanager_viewer" {
  project = var.project_id
  role    = "roles/secretmanager.viewer"
  member  = "serviceAccount:${google_service_account.service_account.email}"
}
resource "google_project_iam_member" "firebaseextensions_viewer" {
  project = var.project_id
  role    = "roles/firebaseextensions.viewer" # Add role to view Firebase Extensions
  member  = "serviceAccount:${google_service_account.service_account.email}"
}

resource "google_project_iam_member" "secretmanager_admin" {
  project = var.project_id
  role    = "roles/secretmanager.admin" # Use this role for project-level secret management permissions
  member  = "serviceAccount:${google_service_account.service_account.email}"
}

# Allow the Cloud Function to create tasks in the queue
resource "google_project_iam_member" "tasks_enqueuer" {
  count = var.enable_cloudtasks ? 1 : 0
  project = var.project_id
  role    = "roles/cloudtasks.enqueuer"
  # Assumes the default App Engine service account is used by the function
  member  = "serviceAccount:${google_service_account.service_account.email}"
}

resource "google_service_account_key" "deployuser-key" {
  service_account_id = google_service_account.service_account.name
}

resource "local_file" "deployuser-key" {
  filename             = "./output/secrets/deployuser-key"
  content              = google_service_account_key.deployuser-key.private_key
  file_permission      = "0600"
  directory_permission = "0755"
}

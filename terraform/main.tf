terraform {
  required_providers {
    google-beta = {
      source                = "hashicorp/google-beta"
      configuration_aliases = [google-beta, google-beta.no_user_project_override]
      version               = "~> 6.0"
    }
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

module "project" {
  source          = "./modules/firebase-project"
  project_id_prefix = var.project_id_prefix 
  project_name      = var.project_name
  billing_account = var.billing_account
  providers = {
    google-beta                          = google-beta
    google-beta.no_user_project_override = google-beta.no_user_project_override
  }
}

module "hosting" {
  source       = "./modules/firebase-hosting"
  project_id   = module.project.project_id
  display_name = "${module.project.project_id} development site"
  providers = {
    google-beta = google-beta
  }
  depends_on = [module.project]
}

module "cloudtasks" {
count = var.enable_realtime_update ? 1 : 0
  source       = "./modules/cloudtasks"
  project_id = module.project.project_id
  region = var.region
  providers = {
    google-beta = google-beta
  }
  depends_on = [module.project, module.service_account]
}

module "service_account" {
  source     = "./modules/service-account"
  project_id = module.project.project_id 
  enable_cloudtasks = var.enable_realtime_update
  providers = {
    google = google
  }
}

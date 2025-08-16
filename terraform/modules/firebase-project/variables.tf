variable "project_id_prefix" {
  type        = string
  description = "Prefix for the Google Cloud project ID. A random suffix will be appended."
}

variable "project_name" {
  type = string
  description = "The human-readable name for the Google Cloud project."
}

variable "billing_account" {
  type = string
  description = "The ID of the billing account to associate the project with. Leave empty if not associating with a billing account (e.g., for hosting-only projects)."
}
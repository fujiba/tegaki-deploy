output "project_id" {
  description = "The generated Google Cloud project ID."
  value       = google_project.default.project_id
}

output "enabled_service_ids" {
  description = "The IDs of the enabled Google Cloud services."
  value       = [for s in google_project_service.default : s.id]
}
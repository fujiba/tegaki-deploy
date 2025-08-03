output "email" {
  description = "The email of the created service account."
  value       = google_service_account.service_account.email
}
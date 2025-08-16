resource "google_cloud_tasks_queue" "gdrive_sync_queue" {
  project  = var.project_id
  location = var.region
  name     = "gdrive-sync-debounce-queue" # A descriptive name for the queue

  # Rate limits to prevent deploy spam
  rate_limits {
    max_dispatches_per_second = 1 # Only one deploy task per second
    max_concurrent_dispatches = 1 # Only one task running at a time
  }

  # Retry config (don't retry too aggressively on failure)
  retry_config {
    max_attempts = 3
    min_backoff  = "10s"
    max_backoff  = "60s"
  }
}
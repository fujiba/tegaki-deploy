variable "project_id" {
  type = string
}

variable "enable_cloudtasks" {
  type = bool
  description = "Whether to use Cloud Tasks for background tasks"
}

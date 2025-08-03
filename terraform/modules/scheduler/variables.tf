variable "project_id" {
  type = string
}

variable "region" {
  type = string
  description = "region name for cloud task"
}

variable "schedule" {
  type = string
  description = "execution schedule"
  default = "1 0 * * *"
}
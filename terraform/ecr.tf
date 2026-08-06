resource "aws_ecr_repository" "chatbot" {
  name                 = "chatbot"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Project = "chatbot"
  }
}

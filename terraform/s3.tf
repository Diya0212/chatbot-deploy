resource "aws_s3_bucket" "faiss_indexes" {
  bucket = "chatbot-faiss-${data.aws_caller_identity.current.account_id}"

  tags = {
    Project = "chatbot"
  }
}

resource "aws_s3_bucket_public_access_block" "faiss_indexes" {
  bucket = aws_s3_bucket.faiss_indexes.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "chatbot_s3" {
  statement {
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.faiss_indexes.arn,
      "${aws_s3_bucket.faiss_indexes.arn}/*",
    ]
  }
}

resource "aws_iam_policy" "chatbot_s3" {
  name   = "chatbot-s3-policy"
  policy = data.aws_iam_policy_document.chatbot_s3.json
}

resource "aws_iam_role_policy_attachment" "chatbot_s3" {
  role       = aws_iam_role.chatbot_irsa.name
  policy_arn = aws_iam_policy.chatbot_s3.arn
}

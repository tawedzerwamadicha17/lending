# Shell access for humans.
#
# There is no EC2 key pair anywhere in this project and no inbound port 22.
# Operators get a shell through SSM Session Manager under their own IAM
# identity, which means access is granted and revoked per person, every
# session is attributable in CloudTrail, and there is no shared secret to
# rotate when someone leaves.
#
# Add a colleague:
#   aws iam add-user-to-group --group-name corebyte-operators --user-name <them>
#
# They then need the Session Manager plugin installed locally, and run:
#   aws ssm start-session --region <region> --target <instance-id>

resource "aws_iam_group" "operators" {
  name = "${var.project}-operators"
}

data "aws_iam_policy_document" "operators" {
  # Start a session only on this project's instances. The tag condition is
  # what stops this from being shell access to the whole account, which
  # matters because other workloads share it.
  statement {
    sid       = "StartSessionOnProjectInstances"
    effect    = "Allow"
    actions   = ["ssm:StartSession"]
    resources = ["arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Project"
      values   = [var.project]
    }
  }

  # The session documents themselves. AWS-StartSSHSession is included so that
  # `ssh -o ProxyCommand=...` and scp work over the same tunnel, for anyone
  # whose tooling needs real SSH -- still with no open port.
  statement {
    sid     = "SessionDocuments"
    effect  = "Allow"
    actions = ["ssm:StartSession"]
    resources = [
      "arn:aws:ssm:${var.aws_region}::document/SSM-SessionManagerRunShell",
      "arn:aws:ssm:${var.aws_region}::document/AWS-StartSSHSession",
    ]
  }

  # Operators may end their own sessions, not other people's.
  statement {
    sid       = "ManageOwnSessions"
    effect    = "Allow"
    actions   = ["ssm:TerminateSession", "ssm:ResumeSession"]
    resources = ["arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:session/$${aws:username}-*"]
  }

  # Enough visibility to find the instance to connect to.
  statement {
    sid    = "DiscoverInstances"
    effect = "Allow"
    actions = [
      "ec2:DescribeInstances",
      "ssm:DescribeInstanceInformation",
      "ssm:DescribeSessions",
      "ssm:GetConnectionStatus",
    ]
    resources = ["*"] # Describe* does not support resource scoping
  }
}

resource "aws_iam_group_policy" "operators" {
  name   = "${var.project}-operators"
  group  = aws_iam_group.operators.name
  policy = data.aws_iam_policy_document.operators.json
}

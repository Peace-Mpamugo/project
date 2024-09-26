provider "aws" {
  region = "us-east-1"
}

variable vpc_cidr_block {}
variable my_ip {}
variable env_prefix {}
variable instance_type{}
variable password {}
variable user {}

resource "aws_lb" "my-balancer" {
  name               = "test-lb-tf"
  internal           = false
  load_balancer_type = "application"
  security_groups = [aws_security_group.myapp-sg.id]
  subnets            = [aws_subnet.myapp-subnet-1.id, aws_subnet.myapp-subnet-2.id]
}

# Create the ALB HTTP Listener
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.my-balancer.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}


# Create the ALB HTTPS Listener
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.my-balancer.arn
  port              = 443
  protocol          = "HTTPS"

  ssl_policy        = "ELBSecurityPolicy-2016-08"
  certificate_arn = aws_acm_certificate.example_cert.arn

  default_action {
    type = "forward"
    target_group_arn = aws_lb_target_group.tg.arn
    
  }
}


# ACM certificate validation
resource "aws_acm_certificate_validation" "example_cert_validation" {
  certificate_arn         = aws_acm_certificate.example_cert.arn
  validation_record_fqdns = [for record in aws_route53_record.example_cert_validation : record.fqdn]
}

resource "aws_route53_zone" "adnexsolutions" {
  name = "adnexsolutions.cloud"
}

# Request ACM certificate for example.com and *.example.com
resource "aws_acm_certificate" "example_cert" {
  domain_name       = "adnexsolutions.cloud"
  validation_method = "DNS"

  subject_alternative_names = ["adnexsolutions.cloud"]

  tags = {
    Name = "adnexsolutions.cloud-cert"
  }
}

# Create DNS validation records in Route 53
resource "aws_route53_record" "example_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.example_cert.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      value  = dvo.resource_record_value
    }
  }

  zone_id = aws_route53_zone.adnexsolutions.zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = 60
  records = [each.value.value]
}



# Find a certificate issued by (not imported into) ACM

# data "aws_acm_certificate" "cert" {
#   domain      = "bello.com"
#   types       = ["AMAZON_ISSUED"]
#   most_recent = true
# }
# resource "aws_acm_certificate" "cert" {
#   domain_name       = "omniblu.com"
#   validation_method = "DNS"

#   tags = {
#     Environment = "test"
#   }

#   lifecycle {
#     create_before_destroy = true
#   }
# }

# resource "aws_route53_zone" "main-zone" {
#   name = "omniblu.com"
# }

# Create a DNS validation record
# resource "aws_route53_record" "cert" {
#   for_each = { for dvo in aws_acm_certificate.cert.domain_validation_options : dvo.domain_name => dvo }

#   name    = each.value.resource_record_name
#   type    = each.value.resource_record_type
#   zone_id = aws_route53_zone.main-zone.id
#   records = [each.value.resource_record_value]
#   ttl     = 60
# }

# Create a Target Group
resource "aws_lb_target_group" "tg" {
  name     = "wordpress-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.myapp-vpc.id
  health_check {
    path                = "/"
    interval            = 30
    timeout             = 5
    healthy_threshold    = 2
    unhealthy_threshold  = 2
  }
}

resource "aws_efs_file_system" "my-file" {
  creation_token = "my-efs"
  performance_mode = "generalPurpose"
}

# Create a mount target for the EFS in the subnet
resource "aws_efs_mount_target" "mount_target" {
  file_system_id = aws_efs_file_system.my-file.id
  subnet_id      = aws_subnet.myapp-subnet-1.id
}


resource "aws_rds_cluster" "my-db" {
  cluster_identifier        = "my-cluster"
  availability_zones        = ["us-east-1a", "us-east-1b", "us-east-1c"]
  engine                    = "mysql"
  db_cluster_instance_class = "db.r6gd.xlarge"
  storage_type              = "io1"
  allocated_storage         = 100
  iops                      = 1000
  master_username           = var.user
  master_password           = var.password
  delete_automated_backups = true
  deletion_protection = false
  apply_immediately = true
}

resource "aws_db_instance" "db-instance" {
  allocated_storage    = 10
  db_name              = "mydb"
  engine               = "mysql"
  engine_version       = "8.0"
  instance_class       = "db.t3.micro"
  username             = var.user
  password             = var.password
  parameter_group_name = "default.mysql8.0"
  delete_automated_backups = true
  deletion_protection = false
  apply_immediately = true
}

# Create a Task Definition for WordPress
resource "aws_ecs_task_definition" "wordpress" {
  family                   = "wordpress-task"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
 

  execution_role_arn = aws_iam_role.my_role.arn

  container_definitions = jsonencode([
    {
      name      = "wordpress"
      image     = "wordpress:latest"
      cpu       = 256
      memory    = 512
      essential = true
      portMappings = [
        {
          containerPort = 80
          hostPort      = 80
        }]
      environment = [
        {
          name  = "WORDPRESS_DB_HOST"
          value = aws_db_instance.db-instance.endpoint
        },
        {
          name  = "WORDPRESS_DB_NAME"
          value = "My-DB"
        },
        {
          name  = "WORDPRESS_DB_USER"
          value = var.user
        },
        {
          name  = "WORDPRESS_DB_PASSWORD"
          value = var.password
        }
      ]
    }
  ])
}

resource "aws_efs_access_point" "access-point" {
  file_system_id = aws_efs_file_system.my-file.id
}

# Create a Fargate Service
resource "aws_ecs_service" "wordpress_service" {
  name            = "wordpress-service"
  cluster         = aws_ecs_cluster.my-cluster.id
  task_definition = aws_ecs_task_definition.wordpress.arn
  desired_count   = 1
  launch_type     = "FARGATE"
  network_configuration {
    subnets          = [aws_subnet.myapp-subnet-1.id, aws_subnet.myapp-subnet-2.id]
    security_groups  = [aws_security_group.myapp-sg.id]
    assign_public_ip = true
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.tg.arn
    container_name   = "wordpress"
    container_port   = 80
  }
  depends_on = [aws_lb_listener.http, aws_lb_listener.https]
}

resource "aws_ecs_cluster" "my-cluster" {
  name = "my-cluster"
}

# Outputs
output "load_balancer_dns_name" {
  value = aws_lb.my-balancer.dns_name
}

output "rds_endpoint" {
  value = aws_db_instance.db-instance.endpoint
}

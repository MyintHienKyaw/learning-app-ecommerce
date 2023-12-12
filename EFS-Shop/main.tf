# Configure the AWS Provider
provider "aws" {
  region = "us-east-1"
}

#Retrieve the list of AZs in the current AWS region
data "aws_availability_zones" "available" {}
data "aws_region" "current" {}

#Define the VPC
resource "aws_vpc" "vpc" {
  cidr_block = var.vpc_cidr

  tags = {
    Name        = var.vpc_name
    Environment = "efs_environment"
    Terraform   = "true"
  }
}

#Deploy the private subnets
resource "aws_subnet" "private_subnets" {
  for_each          = var.private_subnets
  vpc_id            = aws_vpc.vpc.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, each.value)
  availability_zone = tolist(data.aws_availability_zones.available.names)[each.value]

  tags = {
    Name      = each.key
    Terraform = "true"
  }
}

#Deploy the public subnets
resource "aws_subnet" "public_subnets" {
  for_each                = var.public_subnets
  vpc_id                  = aws_vpc.vpc.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, each.value + 100)
  availability_zone       = tolist(data.aws_availability_zones.available.names)[each.value]
  map_public_ip_on_launch = true

  tags = {
    Name      = each.key
    Terraform = "true"
  }
}

#Create route tables for public and private subnets
resource "aws_route_table" "public_route_table" {
  vpc_id = aws_vpc.vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.internet_gateway.id

  }
  tags = {
    Name      = "efs_public_rtb"
    Terraform = "true"
  }
}

resource "aws_route_table" "private_route_table" {
  vpc_id = aws_vpc.vpc.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_gateway.id
  }
  tags = {
    Name      = "efs_private_rtb"
    Terraform = "true"
  }
}

#Create route table associations
resource "aws_route_table_association" "public" {
  depends_on     = [aws_subnet.public_subnets]
  route_table_id = aws_route_table.public_route_table.id
  for_each       = aws_subnet.public_subnets
  subnet_id      = each.value.id
}

resource "aws_route_table_association" "private" {
  depends_on     = [aws_subnet.private_subnets]
  route_table_id = aws_route_table.private_route_table.id
  for_each       = aws_subnet.private_subnets
  subnet_id      = each.value.id
}

#Create Internet Gateway
resource "aws_internet_gateway" "internet_gateway" {
  vpc_id = aws_vpc.vpc.id
  tags = {
    Name = "efs_igw"
  }
}

#Create EIP for NAT Gateway
resource "aws_eip" "nat_gateway_eip" {
  domain     = "vpc"
  depends_on = [aws_internet_gateway.internet_gateway]
  tags = {
    Name = "efs_igw_eip"
  }
}

#Create EIP for the second NAT Gateway
resource "aws_eip" "nat_gateway_eip_2" {
  domain     = "vpc"
  depends_on = [aws_internet_gateway.internet_gateway]
  tags = {
    Name = "efs_igw_eip_2"
  }
}

#Create NAT Gateway for Public subnet
resource "aws_nat_gateway" "nat_gateway" {
  depends_on    = [aws_subnet.public_subnets["public_subnet_1"]]
  allocation_id = aws_eip.nat_gateway_eip.id
  subnet_id     = aws_subnet.public_subnets["public_subnet_1"].id
  tags = {
    Name = "efs_nat_gateway"
  }
}

# Create NAT Gateway for Public subnet 2
resource "aws_nat_gateway" "nat_gateway_2" {
  depends_on    = [aws_subnet.public_subnets["public_subnet_2"]]
  allocation_id = aws_eip.nat_gateway_eip_2.id
  subnet_id     = aws_subnet.public_subnets["public_subnet_2"].id
  tags = {
    Name = "efs_nat_gateway_2"
  }
}

#Create Security Group
resource "aws_security_group" "allow_web" {
  name        = "efs-sg-traffic"
  description = "Allow Web inbound traffic"
  vpc_id      = aws_vpc.vpc.id

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "allow_web"
  }
}

#Create Security Group for app
resource "aws_security_group" "allow_app" {
  name        = "efs-sg-traffic-for-app"
  description = "Allow app inbound traffic"
  vpc_id      = aws_vpc.vpc.id

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "allow_app"
  }
}

# Create a Launch Configuration
resource "aws_launch_configuration" "efs_launch_config" {
  name = "efs-launch-config"

  image_id      = "ami-0230bd60aa48260c6"
  instance_type = "t2.micro"
  key_name      = "efs_keypair"

  security_groups = [aws_security_group.allow_web.id]
}

# Create an Auto Scaling Group
resource "aws_autoscaling_group" "efs_asg" {
  name                = "webserver"
  desired_capacity    = 1
  min_size            = 1
  max_size            = 3
  vpc_zone_identifier = [aws_subnet.public_subnets["public_subnet_1"].id]

  launch_configuration = aws_launch_configuration.efs_launch_config.name
}

# Create a Launch Configuration for Auto Scaling Group 2
resource "aws_launch_configuration" "efs_launch_config_2" {
  name = "efs-launch-config-2"

  image_id      = "ami-0230bd60aa48260c6"
  instance_type = "t2.micro"
  key_name      = "efs_keypair"

  security_groups = [aws_security_group.allow_app.id]
}

# Create an Auto Scaling Group 2
resource "aws_autoscaling_group" "efs_asg_2" {
  name                = "appserver"
  desired_capacity    = 1
  min_size            = 1
  max_size            = 3
  vpc_zone_identifier = [aws_subnet.private_subnets["private_subnet_2"].id]

  launch_configuration = aws_launch_configuration.efs_launch_config_2.name
}

# Create a Load Balancer
resource "aws_lb" "efs_lb" {
  name               = "efs-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.allow_web.id]
  subnets = [
    aws_subnet.public_subnets["public_subnet_1"].id,
    aws_subnet.public_subnets["public_subnet_2"].id,
  ]


  enable_deletion_protection = false

  enable_http2 = true

  enable_cross_zone_load_balancing = false
}

# Create a Target Group
resource "aws_lb_target_group" "efs_target_group" {
  name     = "efs-target-group"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.vpc.id

  health_check {
    path     = "/"
    interval = 30
    port     = 80
    protocol = "HTTP"
    timeout  = 10
  }
}

# Create a Listener for the Load Balancer
resource "aws_lb_listener" "efs_listener" {
  load_balancer_arn = aws_lb.efs_lb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    target_group_arn = aws_lb_target_group.efs_target_group.arn
    type             = "forward"
  }
}

# Create a Load Balancer 2
resource "aws_lb" "efs_lb_2" {
  name               = "efs-lb-2"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.allow_app.id]
  subnets = [
    aws_subnet.public_subnets["public_subnet_1"].id,
    aws_subnet.public_subnets["public_subnet_2"].id,
  ]

  enable_deletion_protection       = false
  enable_http2                     = true
  enable_cross_zone_load_balancing = false
}

# Create a Target Group 2
resource "aws_lb_target_group" "efs_target_group_2" {
  name     = "efs-target-group-2"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.vpc.id

  health_check {
    path     = "/"
    interval = 30
    port     = 80
    protocol = "HTTP"
    timeout  = 10
  }
}

# Create a Listener for Load Balancer 2
resource "aws_lb_listener" "efs_listener_2" {
  load_balancer_arn = aws_lb.efs_lb_2.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    target_group_arn = aws_lb_target_group.efs_target_group_2.arn
    type             = "forward"
  }
}
# Create a DB Subnet Group
resource "aws_db_subnet_group" "private_db_subnet_group" {
  name       = "private-db-subnet-group"
  subnet_ids = values(aws_subnet.private_subnets)[*].id

  tags = {
    Name = "private-db-subnet-group"
  }
}

# Designate the first private subnet as the default subnet
resource "aws_db_subnet_group" "default_db_subnet_group" {
  name       = "default-db-subnet-group"
  subnet_ids = values(aws_subnet.private_subnets)[*].id
}

# Create RDS Instance
resource "aws_db_instance" "efs_db_instance" {
  allocated_storage      = 20
  db_name                = "mydb"
  engine                 = "mysql"
  engine_version         = "5.7"
  instance_class         = "db.t2.micro"
  username               = "efs_user"
  password               = "efs_password"
  parameter_group_name   = "default.mysql5.7"
  skip_final_snapshot    = true
  publicly_accessible    = false
  multi_az               = false
  vpc_security_group_ids = [aws_security_group.allow_app.id]
  db_subnet_group_name   = aws_db_subnet_group.default_db_subnet_group.name
}


# Allow RDS Security Group to access the EC2 instances
resource "aws_security_group_rule" "allow_db_ingress" {
  security_group_id = aws_security_group.allow_app.id

  type        = "ingress"
  description = "db"
  from_port   = 3306
  to_port     = 3306
  protocol    = "tcp"
  cidr_blocks = [for subnet in values(aws_subnet.private_subnets) : subnet.cidr_block]
}
# Service Endpoint
output "rds_endpoint" {
  value = aws_db_instance.efs_db_instance.endpoint
}


output "alb_dns_name" {
  description = "Public DNS name of the application load balancer"
  value       = aws_lb.app_alb.dns_name
}

output "rds_endpoint" {
  description = "Endpoint of the RDS PostgreSQL instance"
  value       = aws_db_instance.app_db.address
}

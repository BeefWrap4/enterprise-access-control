# Security

All checked-in passwords and client secrets are local-development fixtures. Production deployment must inject secrets from a secret manager, enable TLS, set an explicit external hostname, disable the QA client, connect Keycloak to enterprise LDAP/AD, and persist Cerbos audit logs in an approved store.

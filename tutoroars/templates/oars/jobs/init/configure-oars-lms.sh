cat > /tmp/erb_config.json <<EOF
{
  "model": "event_routing_backends.RouterConfiguration",
  "data":
  [
    {
      "enabled": true,
      "backend_name": "xAPI",
      "route_url": "http://ralph:8100/xAPI/",
      "auth_scheme": "Basic",
      "username": "{{ RALPH_LMS_USERNAME }}",
      "password": "{{ RALPH_LMS_PASSWORD }}"
    }
  ]
}
EOF

./manage.py lms manage_user tutor-contrib-oars oars@tcril --unusable-password
./manage.py lms populate_model -f /tmp/erb_config.json -u tutor-contrib-oars

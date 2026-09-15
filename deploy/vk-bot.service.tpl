# Template; scripts/setup_vps.sh substitutes __USER__ / __HOME__ and installs it
# as /etc/systemd/system/vk-bot.service.
[Unit]
Description=VK commentator Telegram bot
After=network-online.target chrony.service
Wants=network-online.target

[Service]
Type=simple
User=__USER__
WorkingDirectory=__HOME__/vk_commentator
ExecStart=/usr/bin/ruby __HOME__/vk_commentator/bot.rb
Restart=always
RestartSec=5
# Spawned commentator.rb runners live in their own process groups and must
# survive bot restarts/deploys: only the bot process itself gets SIGTERM.
KillMode=process
Environment=TZ=Europe/Moscow

[Install]
WantedBy=multi-user.target

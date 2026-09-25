FROM alpine:3.20

RUN apk add --no-cache openssh-server iproute2 curl nmap-ncat \
    && ssh-keygen -A \
    && adduser -D -s /bin/sh admin \
    && echo "admin:trocar-esta-senha" | chpasswd \
    && mkdir -p /home/admin/.ssh

# Copie sua chave pública para bastion/authorized_keys antes de buildar,
# e prefira desabilitar login por senha em produção (PasswordAuthentication no).
COPY authorized_keys /home/admin/.ssh/authorized_keys
RUN chown -R admin:admin /home/admin/.ssh && chmod 700 /home/admin/.ssh && chmod 600 /home/admin/.ssh/authorized_keys

EXPOSE 22
CMD ["/usr/sbin/sshd", "-D", "-e"]

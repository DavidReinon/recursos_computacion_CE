#!/usr/bin/env bash
# cambia_tipo_ec2.sh - Cambia el tipo de una instancia EC2
# Autor/a: David Reinón García
# Fecha: 30/11/2026
# Uso: cambia_tipo_ec2.sh [-y] ID_INSTANCIA TIPO_NUEVO
#
# Códigos de salida:
#   0 Cambio realizado, o nada que hacer (el tipo ya era el pedido)
#   1 Uso incorrecto: número de parámetros u opción desconocida
#   2 La instancia no existe o no es accesible
#   3 La instancia no tiene tu etiqueta Propietario
#   4 La instancia está terminada o terminándose
#   5 Tipo no válido: no existe o no está permitido en el Learner Lab
#   6 Cancelado por el usuario en la confirmación
#   7 Error de AWS durante el cambio

set -uo pipefail
export AWS_PAGER=""         # sin paginador: el script no se detiene

# Solo se modifican las instancias con esta etiqueta Propietario
PROPIETARIO="davidreinon"
I="Reservations[0].Instances[0]"

error() {                   # error MENSAJE CODIGO
    echo "ERROR: $1" >&2
    exit "$2"
}

uso() {
    echo "Uso: $(basename "$0") [-y] ID_INSTANCIA TIPO_NUEVO" >&2
    exit 1
}

# Opciones: -y se salta la confirmación
CONFIRMAR=1
while getopts ":y" OPCION; do
    case "$OPCION" in
        y) CONFIRMAR=0 ;;
        *) uso ;;
    esac
done
shift $((OPTIND - 1))

[ $# -eq 2 ] || uso
ID=$1
TIPO_NUEVO=$2

# Una sola llamada: estado, tipo, propietario y nombre (separados por tabuladores)
DATOS=$(aws ec2 describe-instances --instance-ids "$ID" --output text \
    --query "$I.[State.Name,InstanceType,Tags[?Key=='Propietario'].Value | [0],Tags[?Key=='Name'].Value | [0]]" \
    2>/dev/null) \
    || error "La instancia $ID no existe o no es accesible" 2
IFS=$'\t' read -r ESTADO TIPO_ACTUAL PROPIETARIO_INST NOMBRE <<< "$DATOS"
[ -n "$ESTADO" ] || error "La instancia $ID no existe o no es accesible" 2

# La instancia debe ser nuestra
[ "$PROPIETARIO_INST" = "$PROPIETARIO" ] \
    || error "La instancia $ID no tiene la etiqueta Propietario=$PROPIETARIO" 3

# No se puede tocar una instancia terminada o terminándose
case "$ESTADO" in
    terminated|shutting-down)
        error "La instancia $ID está en estado $ESTADO" 4 ;;
esac

if [ "$TIPO_ACTUAL" = "$TIPO_NUEVO" ]; then
    echo "La instancia $ID ya es de tipo $TIPO_NUEVO; no hay nada que hacer"
    exit 0
fi

# El Learner Lab termina al arrancar las instancias mayores que large:
# se rechazan antes de detener nada
case "${TIPO_NUEVO#*.}" in
    nano|micro|small|medium|large) ;;
    *) error "El tamaño de $TIPO_NUEVO no está permitido en el Learner Lab" 5 ;;
esac
aws ec2 describe-instance-types --instance-types "$TIPO_NUEVO" > /dev/null 2>&1 \
    || error "El tipo $TIPO_NUEVO no existe" 5

# Confirmación (se la salta -y)
if [ "$CONFIRMAR" -eq 1 ]; then
    [ "$NOMBRE" = "None" ] && NOMBRE="(sin nombre)"
    echo "Instancia:   $ID"
    echo "Nombre:      $NOMBRE"
    echo "Estado:      $ESTADO"
    echo "Tipo actual: $TIPO_ACTUAL"
    echo "Tipo nuevo:  $TIPO_NUEVO"
    echo "AVISO: si la instancia está en ejecución se detendrá y se volverá a arrancar."
    RESPUESTA=""
    read -r -p "¿Continuar? (s/N): " RESPUESTA
    [ "$RESPUESTA" = "s" ] || { echo "Cancelado: no se ha cambiado nada"; exit 6; }
fi

# Si está en una transición, se espera a que llegue a un estado estable
case "$ESTADO" in
    pending)
        aws ec2 wait instance-running --instance-ids "$ID" \
            || error "La instancia $ID no llegó a arrancar" 7
        ESTADO="running" ;;
    stopping)
        aws ec2 wait instance-stopped --instance-ids "$ID" \
            || error "La instancia $ID no llegó a detenerse" 7
        ESTADO="stopped" ;;
esac

# Si está en ejecución, se detiene y se espera a que esté detenida
if [ "$ESTADO" = "running" ]; then
    echo "Deteniendo la instancia..."
    aws ec2 stop-instances --instance-ids "$ID" > /dev/null \
        || error "No se pudo detener la instancia $ID" 7
    aws ec2 wait instance-stopped --instance-ids "$ID" \
        || error "La instancia $ID no llegó a detenerse" 7
fi

# Cambio de tipo
echo "Cambiando el tipo de $TIPO_ACTUAL a $TIPO_NUEVO..."
if ! aws ec2 modify-instance-attribute --instance-id "$ID" \
    --instance-type "{\"Value\": \"$TIPO_NUEVO\"}"; then
    # Si estaba en marcha, se intenta dejar como estaba antes de salir
    if [ "$ESTADO" = "running" ]; then
        aws ec2 start-instances --instance-ids "$ID" > /dev/null
    fi
    error "No se pudo cambiar el tipo a $TIPO_NUEVO" 7
fi

# Si estaba en ejecución, se arranca y se espera a que esté en marcha
if [ "$ESTADO" = "running" ]; then
    echo "Arrancando la instancia..."
    aws ec2 start-instances --instance-ids "$ID" > /dev/null \
        || error "No se pudo arrancar la instancia $ID" 7
    aws ec2 wait instance-running --instance-ids "$ID" \
        || error "La instancia $ID no llegó a arrancar" 7
fi

# Se vuelve a consultar AWS para comprobar el resultado
DATOS=$(aws ec2 describe-instances --instance-ids "$ID" --output text \
    --query "$I.[State.Name,InstanceType]") \
    || error "No se pudo consultar el estado final de $ID" 7
read -r ESTADO_FINAL TIPO_FINAL <<< "$DATOS"
echo "Estado final: $ESTADO_FINAL, tipo final: $TIPO_FINAL"

[ "$TIPO_FINAL" = "$TIPO_NUEVO" ] \
    || error "El tipo final ($TIPO_FINAL) no coincide con el pedido ($TIPO_NUEVO)" 7
[ "$ESTADO_FINAL" = "$ESTADO" ] \
    || error "El estado final ($ESTADO_FINAL) no coincide con el inicial ($ESTADO)" 7

echo "Tiempo total: $((SECONDS / 60)) min $((SECONDS % 60)) s"

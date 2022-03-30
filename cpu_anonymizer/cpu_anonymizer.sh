#!/bin/bash

#=======================================================================

for cmd in vboxmanage od sed bc head tr awk; do
  if ! [ -x "$(command -v "$cmd")" ]; then
    echo "Programa ${cmd} Não encontrado."
    exit 1
  fi
done

#=======================================================================

vboxmanage list vms
echo "Digite o nome da máquina virtual para anonimizar o CPU:"
read vm
  if [ ! "$(vboxmanage list vms | grep "${vm}")" ]; then
    echo "Máquina virtual inexistente."
    exit 1
  fi

#=======================================================================

echo "Escolha a marca de seu processador ( intel | amd ):"
read vendor
  case ${vendor} in
              intel)
                vendor='GenuineIntel'
                shift
              ;;
              amd)
                vendor='AuthenticAMD'
                shift
              ;;
              *)
                echo "Marca desconhecida."
                exit 1
              ;;
  esac

#=======================================================================

ascii2hex() { echo -n 0x; od -A n --endian little -t x4 | sed 's/ //g'; }

registers=(ebx edx ecx)
for (( i=0; i<${#vendor}; i+=4 )); do
    register=${registers[$(($i/4))]}
    value=`echo -n "${vendor:$i:4}" | ascii2hex`
    for eax in 00000000 80000000; do
        key=VBoxInternal/CPUM/HostCPUID/${eax}/${register}
        vboxmanage setextradata "$vm" $key $value
    done
done

#=======================================================================

brand="$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 47)"

ascii2hex() { echo -n 0x; od -A n --endian little -t x4 | sed 's/ //g'; }
ascii2bin() { 
    HEX=$(od -A n --endian little -t x4 | sed 's/ //g' | tr 'a-f' 'A-F')
    echo "obase=2; ibase=16; $HEX" | BC_LINE_LENGTH=9999 bc | awk '{
        s="00000000000000000000000000000000"$0; 
        t = substr( s, length(s) - 31, length(s)); 
        gsub(/..../,"&:",t);
        printf("%s",substr(t, 1, length(t)-1));
    }'
}

eax_values=(80000002 80000003 80000004)
registers=(eax ebx ecx edx)
for (( i=0; i<${#brand}; i+=4 )); do
    eax=${eax_values[$((${i} / 4 / 4))]}
    register=${registers[$((${i} / 4 % 4 ))]}
    key=VBoxInternal/CPUM/HostCPUID/${eax}/${register}
    value=`echo -n "${brand:$i:4}" | ascii2hex`
    vboxmanage setextradata "$vm" $key $value
done

#=======================================================================

vboxmanage setextradata "${vm}" VBoxInternal/CPUM/HostCPUID/00000001/eax 0x00100f53
vboxmanage setextradata "${vm}" VBoxInternal/CPUM/HostCPUID/80000001/eax 0x00100f53

#=======================================================================

echo "Máquina virtual modificada com sucesso!"

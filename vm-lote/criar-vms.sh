#!/bin/bash
# Este é o shebang, que indica qual interpretador deve ser usado para executar o script.
# Neste caso, é o Bash, um shell comum em sistemas Linux/Unix.

# -----------------------------------------------------------------------------
# Bloco 1: Definição de Variáveis de Ambiente
# -----------------------------------------------------------------------------
# Neste bloco, definimos variáveis que serão usadas em todo o script.
# Isso torna o script mais fácil de configurar e manter, pois valores importantes
# como nomes de recursos são centralizados e podem ser alterados em um único lugar.

KEY_NAME="devops-keypair-01" # Nome da chave SSH (Key Pair) que será criada ou utilizada na AWS.
                            # Usada para acessar as instâncias EC2 de forma segura via SSH.
SG_NAME="devops-sg-ie"      # Nome do Security Group (Grupo de Segurança) que será criado ou utilizado na AWS.
                            # O Security Group atua como um firewall virtual para controlar o tráfego
                            # de entrada e saída das instâncias EC2.

# -----------------------------------------------------------------------------
# Bloco 2: Função para Obter AMI ID do Ubuntu 22.04 LTS
# -----------------------------------------------------------------------------
# Esta função encapsula a lógica para encontrar a AMI (Amazon Machine Image) mais recente
# do Ubuntu 22.04 LTS.
# O porquê de ser uma função: Reusabilidade e clareza. Evita a duplicação de código
# e torna o script mais legível.
# O porquê dos filtros: Garante que estamos selecionando a imagem correta do Ubuntu (owner Canonical),
# a versão específica (22.04 Jammy), e a arquitetura (x86_64), além de buscar a mais recente
# (`sort_by(@, &CreationDate)[-1]`).

get_ubuntu_ami_id() {
    aws ec2 describe-images \
    --owners 099720109477 \
    --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
              "Name=architecture,Values=x86_64" \
    --query "Images | sort_by(@, &CreationDate)[-1].ImageId" \
    --output text
}

# -----------------------------------------------------------------------------
# Bloco 3: Localização de Recursos Existentes (VPC, Subnet e AMI)
# -----------------------------------------------------------------------------
# Antes de criar instâncias, precisamos saber em qual rede elas serão lançadas e
# qual sistema operacional elas usarão. Este bloco consulta a AWS para obter
# IDs de recursos já existentes.
# O porquê: Reutilizamos recursos padrão da conta AWS, como a VPC e Subnet default,
# simplificando o script e evitando a necessidade de criar uma nova infraestrutura de rede.

VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
# Obtém o ID da VPC (Virtual Private Cloud) padrão da sua conta AWS.
# Filtra por 'isDefault=true' para garantir que seja a VPC criada por padrão.

SUBNET_ID=$(aws ec2 describe-subnets --filters Name=defaultForAz,Values=true --query 'Subnets[0].SubnetId' --output text)
# Obtém o ID de uma Subnet padrão. Instâncias são lançadas dentro de Subnets.
# Filtra por 'defaultForAz=true' para pegar uma subnet padrão em uma Availability Zone.

# Chama a função definida anteriormente para obter o ID da AMI do Ubuntu 22.04 LTS.
AMI_ID=$(get_ubuntu_ami_id)

# -----------------------------------------------------------------------------
# Bloco 4: Validação de Recursos Encontrados
# -----------------------------------------------------------------------------
# Este bloco verifica se os IDs da VPC, Subnet e AMI foram obtidos com sucesso.
# O porquê: É crucial garantir que os recursos de rede e a imagem do sistema
# operacional estão disponíveis antes de prosseguir. Se algum deles não for encontrado,
# o script não poderá criar as instâncias e deve sair para evitar erros posteriores.

if [ -z "$VPC_ID" ] || [ -z "$SUBNET_ID" ] || [ -z "$AMI_ID" ]; then
    echo "Erro: Não foi possível encontrar a VPC padrão, Subnet padrão ou a AMI do Ubuntu 22.04 LTS."
    exit 1 # Sai do script com código de erro 1.
fi

echo "VPC ID: $VPC_ID"
echo "Subnet ID: $SUBNET_ID"
echo "AMI ID (Ubuntu 22.04 LTS): $AMI_ID"

# -----------------------------------------------------------------------------
# Bloco 5: Gerenciamento do Key Pair (Chave SSH)
# -----------------------------------------------------------------------------
# Este bloco lida com a criação e verificação do Key Pair (par de chaves SSH)
# necessário para acessar as instâncias.
# O porquê: Um Key Pair é fundamental para a segurança e acesso às instâncias.
# Este bloco garante que um Key Pair com o nome especificado existe na AWS e,
# se não existir, o cria e salva sua parte privada (`.pem`) localmente.
# O tratamento de erro (`$? -ne 0`) verifica se o comando `describe-key-pairs`
# falhou (indicando que a chave não existe).

# Verifica se o keypair já existe na AWS (o `> /dev/null 2>&1` suprime a saída para não poluir o terminal).
aws ec2 describe-key-pairs --key-names "$KEY_NAME" > /dev/null 2>&1

if [ $? -ne 0 ]; then
    # Se o comando acima falhou (Key Pair não existe na AWS):
    echo "Criando o keypair $KEY_NAME na AWS e salvando localmente como $KEY_NAME.pem"
    aws ec2 create-key-pair --key-name "$KEY_NAME" \
    --query 'KeyMaterial' --output text > "$KEY_NAME.pem"
    # O `KeyMaterial` contém a chave privada, que é salva no arquivo .pem.
    chmod 400 "$KEY_NAME.pem" # Define permissões restritivas (apenas leitura para o proprietário)
                              # para a chave privada, uma exigência de segurança para SSH.
else
    # Se o comando acima foi bem-sucedido (Key Pair já existe na AWS):
    echo "O keypair $KEY_NAME já existe na AWS."
    if [ ! -f "$KEY_NAME.pem" ]; then
        # Se a chave existe na AWS, mas o arquivo .pem não está no diretório local:
        echo "Aviso: O arquivo local $KEY_NAME.pem não foi encontrado. Você precisará obtê-lo manualmente para acessar as instâncias via SSH."
        # Decidimos não sair do script aqui. A ausência do .pem local não impede a criação da instância,
        # apenas o acesso SSH posterior. O usuário pode ter a chave em outro lugar ou obter de volta.
    else
        echo "O arquivo local $KEY_NAME.pem já existe."
    fi
fi

# -----------------------------------------------------------------------------
# Bloco 6: Gerenciamento do Security Group
# -----------------------------------------------------------------------------
# Este bloco verifica a existência do Security Group especificado e o cria se necessário.
# Ele também garante que uma regra de entrada para SSH (porta 22) esteja presente.
# O porquê: O Security Group é essencial para permitir a comunicação com as instâncias.
# A regra SSH é vital para que você possa se conectar às VMs após a criação.
# A verificação de existência evita erros de duplicação se o script for executado várias vezes.

# Tenta obter o ID do Security Group. Filtra por nome e VPC ID para ser mais específico.
SG_ID=$(aws ec2 describe-security-groups \
 --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
 --query 'SecurityGroups[0].GroupId' --output text)

if [ -z "$SG_ID" ]; then
    # Se SG_ID estiver vazio, significa que o Security Group não foi encontrado e precisa ser criado.
    echo "Criando o Security Group $SG_NAME na VPC $VPC_ID"
    SG_ID=$(aws ec2 create-security-group \
     --group-name "$SG_NAME" \
     --description "Security Group para acesso SSH" \
     --vpc-id "$VPC_ID" \
     --query 'GroupId' --output text)
    echo "Security Group $SG_NAME criado com ID: $SG_ID"

    # Adiciona a regra de entrada para SSH (porta 22) para todo o tráfego (0.0.0.0/0).
    # O porquê: Permite que você (ou qualquer IP) acesse a instância via SSH.
    echo "Adicionando regra de SSH (porta 22) ao Security Group $SG_NAME"
    aws ec2 authorize-security-group-ingress \
     --group-id "$SG_ID" \
     --protocol tcp \
     --port 22 \
     --cidr 0.0.0.0/0
else
    # Se o Security Group já existe:
    echo "O Security Group $SG_NAME (ID: $SG_ID) já existe. Verificando/Adicionando regra de SSH."
    # Verifica se a regra de SSH (porta 22 de 0.0.0.0/0) já existe para evitar erro de regra duplicada.
    RULE_EXISTS=$(aws ec2 describe-security-groups \
        --group-ids "$SG_ID" \
        --query "SecurityGroups[0].IpPermissions[?ToPort==`22` && FromPort==`22` && IpProtocol=='tcp' && contains(IpRanges[].CidrIp, '0.0.0.0/0')]" \
        --output text)

    if [ -z "$RULE_EXISTS" ]; then
        # Se a regra não existe, a adiciona.
        echo "Adicionando regra de SSH (porta 22) ao Security Group $SG_NAME"
        aws ec2 authorize-security-group-ingress \
            --group-id "$SG_ID" \
            --protocol tcp \
            --port 22 \
            --cidr 0.0.0.0/0
    else
        # Se a regra já existe, apenas informa.
        echo "Regra de SSH (porta 22) já existe no Security Group $SG_NAME."
    fi
fi

# -----------------------------------------------------------------------------
# Bloco 7: Criação de Instâncias EC2 em Loop
# -----------------------------------------------------------------------------
# Este bloco define uma lista de nomes para as instâncias e itera sobre eles,
# criando uma instância EC2 para cada nome.
# O porquê: Automação da criação de múltiplas instâncias com configurações semelhantes,
# ideal para ambientes de desenvolvimento ou teste.

# Lista de nomes para as instâncias que serão criadas.
INSTANCE_NAMES=(vm01 vm02 vm03)

# Inicia um loop `for` que itera sobre cada nome na lista `INSTANCE_NAMES`.
for NAME in "${INSTANCE_NAMES[@]}"; do
    echo "Verificando se a instância $NAME já existe..."
    # Antes de criar, verifica se uma instância com este nome (tag "Name")
    # e em um estado ativo (pending, running, stopping, stopped) já existe.
    # O porquê: Evita a criação acidental de instâncias duplicadas se o script
    # for executado mais de uma vez ou parcialmente.
    INSTANCE_ID_EXISTING=$(aws ec2 describe-instances \
        --filters "Name=tag:Name,Values=$NAME" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query "Reservations[].Instances[0].InstanceId" \
        --output text)

    if [ -n "$INSTANCE_ID_EXISTING" ]; then
        # Se a instância já existe, informa e pula para o próximo item no loop.
        echo "A instância $NAME (ID: $INSTANCE_ID_EXISTING) já existe. Pulando a criação."
        continue
    fi

    echo "Criando a instância $NAME..."

    # Comando para criar a instância EC2.
    INSTANCE_ID=$(aws ec2 run-instances \
     --image-id "$AMI_ID" \
     --count 1 \
     --instance-type t2.micro \
     --key-name "$KEY_NAME" \
     --security-group-ids "$SG_ID" \
     --subnet-id "$SUBNET_ID" \
     --associate-public-ip-address \
     --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME}]" \
     --query 'Instances[0].InstanceId' --output text)
    # --image-id: ID da AMI a ser usada (Ubuntu 22.04 LTS neste caso).
    # --count 1: Cria apenas uma instância por vez.
    # --instance-type t2.micro: Tipo da instância (nível gratuito da AWS).
    # --key-name: Nome da chave SSH para acesso.
    # --security-group-ids: IDs dos Security Groups a serem associados.
    # --subnet-id: ID da Subnet onde a instância será lançada.
    # --associate-public-ip-address: Atribui um endereço IP público para acesso via internet.
    # --tag-specifications: Adiciona uma tag "Name" à instância, útil para identificação.
    # --query 'Instances[0].InstanceId': Extrai apenas o ID da instância da saída JSON.

    echo "$NAME criada com ID: $INSTANCE_ID"

    # Aguarda a instância estar no estado "running" antes de prosseguir para a próxima.
    # O porquê: Garante que a instância está totalmente provisionada e inicializada
    # antes de considerar a operação completa, o que é útil para scripts subsequentes
    # que possam depender da instância estar ativa.
    echo "Aguardando a instância $NAME estar em execução..."
    aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
    echo "A instância $NAME está em execução."
done
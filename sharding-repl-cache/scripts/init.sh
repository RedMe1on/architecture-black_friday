wait_for_mongo() {
  local host=$1
  local port=$2
  echo "Ожидание $host:$port..."
  until docker compose exec -T "$host" mongosh --port "$port" --eval "db.adminCommand('ping')" &>/dev/null; do
    sleep 2
  done
}

wait_for_redis() {
  echo "Ожидание Redis на $1:6379..."
  until docker compose exec -T "$1" redis-cli ping | grep PONG > /dev/null; do
    sleep 2
  done
}

echo "--- Инициализация инфраструктуры MongoDB ---"

# 1. Инициализация Config Server
wait_for_mongo configSrv 27017
docker compose exec -T configSrv mongosh --port 27017 --quiet <<EOF
try {
  rs.initiate({
    _id: "config_server",
    configsvr: true,
    members: [{ _id: 0, host: "configSrv:27017" }]
  });
  print("Config Server initiated");
} catch (e) { print("Config Server already initiated or error: " + e.message); }
EOF

# 2. Инициализация Shard 1
wait_for_mongo shard1 27018
docker compose exec -T shard1 mongosh --port 27018 --quiet <<EOF
try {
  rs.initiate({
    _id: "shard1",
    members: [{ _id: 0, host: "shard1:27018" }, { _id: 1, host: "shard1_replica1:27018" }, { _id: 2, host: "shard1_replica2:27018" }]
  });
  print("Shard 1 initiated");
} catch (e) { print("Shard 1 already initiated"); }
EOF

# 3. Инициализация Shard 2
wait_for_mongo shard2 27019
docker compose exec -T shard2 mongosh --port 27019 --quiet <<EOF
try {
  rs.initiate({
    _id: "shard2",
    members: [{ _id: 0, host: "shard2:27019" }, { _id: 1, host: "shard2_replica1:27019" },{ _id: 2, host: "shard2_replica2:27019" }]
  });
  print("Shard 2 initiated");
} catch (e) { print("Shard 2 already initiated"); }
EOF

# 4. Настройка маршрутизации (через mongos)
# ВАЖНО: Команды шардирования выполняются на порту 27020 (обычно контейнер mongos_router)
wait_for_mongo mongos_router 27020

echo "Настройка шардирования и наполнение данными..."

docker compose exec -T mongos_router mongosh --port 27020 --quiet <<EOF
// Добавление шардов
try { sh.addShard("shard1/shard1:27018"); } catch(e) { print("Shard1 already added"); }
try { sh.addShard("shard2/shard2:27019"); } catch(e) { print("Shard2 already added"); }

// Настройка базы и коллекции
sh.enableSharding("somedb");
sh.shardCollection("somedb.helloDoc", { "name": "hashed" });

// Наполнение данными
var db = db.getSiblingDB("somedb");
if (db.helloDoc.countDocuments() <= 1000) {
    var docs = [];
    for(var i = 0; i < 1100; i++) {
        docs.push({age: i, name: "ly" + i});
    }
    db.helloDoc.insertMany(docs);
    print("Inserted 1100 documents");
} else {
    print("Collection already has data");
}

print("Total documents in somedb.helloDoc: " + db.helloDoc.countDocuments());
EOF

echo "--- Инициализация завершена ---"

echo "--- Проверка распределения данных по шардам ---"

echo -n "Документов на Shard 1 (порт 27018): "
docker compose exec -T shard1 mongosh --port 27018 --quiet --eval 'db.getSiblingDB("somedb").helloDoc.countDocuments()'

echo -n "Документов на Shard 2 (порт 27019): "
docker compose exec -T shard2 mongosh --port 27019 --quiet --eval 'db.getSiblingDB("somedb").helloDoc.countDocuments()'

echo "--- Проверка шардирования завершена ---"

echo "--- Проверка количества реплик в шардах ---"

# Проверка Shard 1
echo -n "Количество узлов в Shard 1 (RS): "
docker compose exec -T shard1 mongosh --port 27018 --quiet --eval "rs.status().members.length"
docker compose exec -T shard1 mongosh --port 27018 --quiet --eval "
  rs.status().members.forEach(function(m) { 
    print('  - ' + m.name + ' [' + m.stateStr + ']'); 
  })
"

echo "------------------------------------------"

# Проверка Shard 2
echo -n "Количество узлов в Shard 2 (RS): "
docker compose exec -T shard2 mongosh --port 27019 --quiet --eval "rs.status().members.length"
docker compose exec -T shard2 mongosh --port 27019 --quiet --eval "
  rs.status().members.forEach(function(m) { 
    print('  - ' + m.name + ' [' + m.stateStr + ']'); 
  })
"

# echo "--- Скрипт полностью выполнен ---"


# for i in {1..6}; do
#   wait_for_redis "redis_$i"
# done

# echo "Создание кластера..."
# # Используем IP из твоей подсети 10.50.x.x (проверь соответствие в docker-compose)
# docker compose exec -T redis_1 sh -c "echo 'yes' | redis-cli --cluster create \
#   11.55.0.15:6379 \
#   11.55.0.16:6379 \
#   11.55.0.17:6379 \
#   11.55.0.18:6379 \
#   11.55.0.19:6379 \
#   11.55.0.20:6379 \
#   --cluster-replicas 1"

# echo "Проверка статуса кластера:"
# docker compose exec -T redis_1 redis-cli cluster nodes
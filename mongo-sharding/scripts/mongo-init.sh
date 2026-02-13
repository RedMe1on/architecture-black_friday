wait_for_mongo() {
  local host=$1
  local port=$2
  echo "Ожидание $host:$port..."
  until docker compose exec -T "$host" mongosh --port "$port" --eval "db.adminCommand('ping')" &>/dev/null; do
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
    members: [{ _id: 0, host: "shard1:27018" }]
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
    members: [{ _id: 1, host: "shard2:27019" }]
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
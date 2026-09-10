# umatl-ru

Русификатор для Umamusume: Pretty Derby. Может содержать ошибки. Перевод машинный.

## Установка

1. Установите [Hachimi](https://github.com/kairusds/Hachimi-Edge), следуя инструкциям в репозитории.

    > **Примечание:** На глобальной версии игры работает только на ПК.

2. Запустите игру один раз. В корневой папке игры появится папка `hachimi` с файлом `config.json`.

3. Откройте файл `config.json` и измените значение `translation_repo_index` чтобы получилось так:

    ```json
    "translation_repo_index": "https://raw.githubusercontent.com/umatl-ru/hachimi-tl-ru/refs/heads/main/index.json"
    ```

4. Перезапустите игру или запустите принудительное обновление в меню Hachimi для применения перевода.

## Исправление ошибок

- **Кривое отображение интерфейса после обновления**
    > Удалите папки an_texture_sets, atlas, textures из папки /localized_data/assets/ и принудительно запустите обновление перевода.

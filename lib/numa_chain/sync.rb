require './app/models/transaction'
module NumaChain
  class Sync
    class << self

      def sync!
        client = Networker.get_client
        contract = Contract.numa
        contract_account = Account.make_by_address(contract.hash_address)
        cache_key = 'last_block_synced'
        cached_min_block = Rails.cache.read(cache_key)&.to_i
        min_block_num = cached_min_block || contract_account.to_transactions.maximum('block_number')
        max_block_num = client.eth_block_number['result'].from_hex
        (min_block_num..max_block_num).each do |block_number|
          Rails.logger.info("Syncing block ##{block_number}")
          block = client.eth_get_block_by_number(block_number, true)['result']

          block['transactions'].each do |transaction|
            next if transaction['to'].blank? || transaction['to'].casecmp(contract.hash_address) != 0
            tx = Transaction.make_by_address(transaction['hash'], data: transaction)
            next if tx.transactable&.confirmed?
            output, status = Open3.capture2('node', 'app/javascript/commands/decode-transaction.js', tx.input)
            if status.exitstatus == 0
              res = JSON.parse(output)
              hash = res['params'].first['value'][2..-1]
              ipfs_hash = IpfsServer.data_to_hash(18, 32, hash)
              process_batch(tx, ipfs_hash)
            else
              Raven.capture_message("Error when decoding transaction input for hash: #{tx.hash_address}")
            end
          end
        end
        Rails.cache.write(cache_key, max_block_num)
      end

      def process_batch(tx, ipfs_hash)
        sender = tx.from_account
        begin
          json = IpfsServer.cat(ipfs_hash)
          json.orderedItems.each do |item|
            if item.type == "Person"
              process_account(tx, item)
            elsif ['Note','Article'].include?(item.type)
              process_message(tx, item)
            elsif item.type == "Follow"
              process_follow(tx, item)
            elsif item.type == "Like"
              process_favorite(tx, item)
            end
          end
          begin
            batch = Batch.find_by!(uuid: json.uuid, account_id: sender.id)
          rescue ActiveRecord::RecordNotFound
            batch = sender.fetch_batch
          end
          tx.update(transactable: batch)
          batch.confirm!
        rescue => e
          raise e if Rails.env.test?
          Raven.capture_exception(e)
          Rails.logger.error(e.backtrace[0..5].join("\n"))
          Rails.logger.error(e)
        end
      end

      def process_account(tx, json)
        account = tx.from_account
        username = json.preferredUsername.downcase
        if Account.where.not(id: account.id).where("lower(username) = ?", username).first.present?
          username = "#{username}_#{SecureRandom.hex(5)}"
        end
        account.confirm!
        account.update!(
          username: username,
          bio: json.summary,
          display_name: json.name,
          avatar_ipfs_hash: json.try(:icon).try(:ipfs_hash),
        )
      end

      def process_message(tx, json)
        message = tx.from_account.messages.find_or_initialize_by(uuid: json.uuid)
        if json.type == "Note"
          message.update_attributes(
            json_schema: :micro,
            body: json.plainTextContent,
            hidden_at: json.hiddenAt,
          )
        elsif json.type == "Article"
          message.update_attributes(
            json_schema: :article,
            body: json.plainTextContent,
            title: json.name,
            tldr: json.summary,
            hidden_at: json.hiddenAt,
          )
        end
        message.confirm!
        message
      end

      def process_follow(tx, json)
        follow = tx.from_account.from_follows.find_or_initialize_by(uuid: json.uuid)
        to_account = Account.make_by_address(json.object.address)
        follow.update(
          to_account: to_account,
          hidden_at: json.hiddenAt,
        )
        follow.confirm!
        follow
      end

      def process_favorite(tx, json)
        favorite = tx.from_account.favorites.find_or_initialize_by(uuid: json.uuid)
        message = Message.find_by(uuid: json.object.uuid)
        favorite.update(
          message: message,
          hidden_at: json.hiddenAt,
        )
        favorite.confirm!
        favorite
      end

      # def sync_tip(tip, sender: , json: , tx: , message_data: )
      #   tip ||= tx.from_account.from_tips.new
      #   to_account = Account.make_by_address(json.object.address)
      #   # tip_tx = Transaction.find_by(address: json.transactionHash)
      #   tip_tx = Transaction.make_by_address(json.transactionHash)
      #   tip_attrs = {
      #     tx: tip_tx,
      #     to_account: to_account,
      #     tx_hash: json.transactionHash,
      #     ipfs_hash: message_data.ipfs_hash,
      #     foreign_id: message_data.foreign_id,
      #   }
      #   to_message = Message.find_by(foreign_id: json.object.foreign_id) || Message.find_by(uuid: json.object.uuid)
      #   if to_message.present?
      #     tip_attrs[:to_message] = to_message
      #   end
      #   tip.update(tip_attrs)
      #   tx.update(transactable: tip)
      #   tip
      # end

    end
  end
end
require 'yasuri'
require 'json'
require 'thor'

ROOT_URL   = 'http://bookmeter.com'
USER_ID    = '104835'
LOGIN_URL  = "#{ROOT_URL}/login"
MYPAGE_URL = "#{ROOT_URL}/u/#{USER_ID}"
BOOKLIST_URL = "#{ROOT_URL}/u/#{USER_ID}/booklist" # 読んだ本
NUM_BOOKS_PER_PAGE = 40.freeze

def login(mail, password)
  agent = Mechanize.new do |a|
    a.user_agent_alias = 'Mac Safari'
  end

  agent.get(LOGIN_URL) do |page|
    page.form_with(action: '/login') do |form|
      form.field_with(name: 'mail').value = mail
      form.field_with(name: 'password').value = password
    end.submit
  end

  agent
end

def get_all_read_books(agent)
  booklist_pages_root = Yasuri.pages_root '//span[@class="now_page"]/following-sibling::span[1]/a' do
    text_page_index '//span[@class="now_page"]/a'
    1.upto(NUM_BOOKS_PER_PAGE) do |i|
      send("text_book_#{i}_name", "//*[@id=\"main_left\"]/div/div[#{i + 1}]/div[2]/a")
      send("text_book_#{i}_link", "//*[@id=\"main_left\"]/div/div[#{i + 1}]/div[2]/a/@href")
    end
  end
  booklist_first_page = agent.get(BOOKLIST_URL)
  booklist_pages_root.inject(agent, booklist_first_page)
end

# @return [Hash] keys are 'year', 'month' and 'day'
def get_read_date(agent, book_link)
  book_page = agent.get(ROOT_URL + book_link)
  book_date = Yasuri.struct_date '//*[@id="book_edit_area"]/form[1]/div[2]' do
    text_year  '//*[@id="read_date_y"]/option[1]', truncate: /\d+/, proc: :to_i
    text_month '//*[@id="read_date_m"]/option[1]', truncate: /\d+/, proc: :to_i
    text_day   '//*[@id="read_date_d"]/option[1]', truncate: /\d+/, proc: :to_i
  end
  book_date.inject(agent, book_page)
end

def get_reread_date(agent, book_link)
  book_page = agent.get(ROOT_URL + book_link)
  book_reread_date = Yasuri.struct_reread_date '//*[@id="book_edit_area"]/div/form[1]/div[2]' do
    text_reread_year  '//div[@class="reread_box"]/form[1]/div[2]/select[1]/option[1]', truncate: /\d+/, proc: :to_i
    text_reread_month '//div[@class="reread_box"]/form[1]/div[2]/select[2]/option[1]', truncate: /\d+/, proc: :to_i
    text_reread_day   '//div[@class="reread_box"]/form[1]/div[2]/select[3]/option[1]', truncate: /\d+/, proc: :to_i
  end
  book_reread_date.inject(agent, book_page)
end

# @param [] Mechanize agent
# @param [Time] target year-month
# @param [] page where searching for
# @return [Array]
def get_target_books(agent, target_ym, page)
  target_books = []

  1.upto(NUM_BOOKS_PER_PAGE) do |i|
    next if page["book_#{i}_link"].empty?

    read_yms = []
    read_date = get_read_date(agent, page["book_#{i}_link"])
    read_yms << Time.local(read_date['year'], read_date['month'])

    reread_date = []
    reread_date << get_reread_date(agent, page["book_#{i}_link"])
    reread_date.flatten!

    unless reread_date.empty?
      reread_date.each do |date|
        read_yms << Time.local(date['reread_year'], date['reread_month'])
      end
    end

    next unless read_yms.include?(target_ym)

    book = { 'name' => page["book_#{i}_name"] }
    book.merge!(read_date)
    unless reread_date.empty?
      reread_date.each_with_index do |d, idx|
        h = { "reread_#{idx + 1}_year"  => d['reread_year'],
              "reread_#{idx + 1}_month" => d['reread_month'],
              "reread_#{idx + 1}_day"   => d['reread_day'] }
        book.merge!(h)
      end
    end
    target_books << book
  end

  target_books
end

def get_last_book_date(agent, page)
  NUM_BOOKS_PER_PAGE.downto(1) do |i|
    link = page["book_#{i}_link"]
    next if link.empty?
    return get_read_date(agent, link)
  end
end

class BookMeterCLI < Thor
  desc 'booklist YEAR MONTH', 'Get read books list in YEAR-MONTH'
  def booklist(mail, password, year, month)
    agent = login(mail, password)
    all_read_books = get_all_read_books(agent)
    target_ym = Time.local(year, month)
    result = []
    all_read_books.each do |page|
      puts "Search page #{page['page_index']}..."
      first_book_date = get_read_date(agent, page['book_1_link'])
      last_book_date  = get_last_book_date(agent, page)

      first_book_ym = Time.local(first_book_date['year'].to_i, first_book_date['month'].to_i)
      last_book_ym  = Time.local(last_book_date['year'].to_i, last_book_date['month'].to_i)

      if target_ym < last_book_ym
        next
      elsif target_ym == first_book_ym && target_ym > last_book_ym
        result.concat(get_target_books(agent, target_ym, page))
        break
      elsif target_ym < first_book_ym && target_ym > last_book_ym
        result.concat(get_target_books(agent, target_ym, page))
        break
      elsif target_ym <= first_book_ym && target_ym >= last_book_ym
        result.concat(get_target_books(agent, target_ym, page))
      elsif target_ym > first_book_ym
        break
      end
    end
    puts result
  end
end

BookMeterCLI.start(ARGV)

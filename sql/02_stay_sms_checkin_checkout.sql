-- Stay texts lead with the check-in and check-out times so a short SMS
-- still carries both, even when the stay name is long.
update public.notification_templates
set body_template = case code
  when 'BOOKING_CONFIRMED_CUSTOMER' then
    'Check in {{check_in_date}} at {{check_in_time}}. Check out {{check_out_date}} at {{check_out_time}}. Your stay at {{property_title}} is confirmed. Ref {{booking_code}}.'
  when 'STAY_TOMORROW_CUSTOMER' then
    'Check in {{check_in_date}} at {{check_in_time}}. Check out {{check_out_date}} at {{check_out_time}}. Your stay at {{property_title}} starts tomorrow. Ref {{booking_code}}.'
  when 'STAY_CHECKIN_WINDOW' then
    'Check in {{check_in_date}} at {{check_in_time}}. Check out {{check_out_date}} at {{check_out_time}}. Check-in is open at {{property_title}}. Ref {{booking_code}}.'
  when 'GUEST_STAY_BEFORE_CHECKOUT' then
    'Check out {{check_out_date}} at {{check_out_time}}. You checked in {{check_in_date}} at {{check_in_time}}. Your stay at {{property_title}} ends tomorrow. Ref {{booking_code}}.'
  when 'BOOKING_CONFIRMED_AGENT' then
    'Check in {{check_in_date}} at {{check_in_time}}. Check out {{check_out_date}} at {{check_out_time}}. New booking for {{customer_name}} at {{property_name}}. Ref {{booking_code}}.'
  when 'HOST_STAY_TOMORROW' then
    'Check in {{check_in_date}} at {{check_in_time}}. Check out {{check_out_date}} at {{check_out_time}}. {{customer_name}} arrives tomorrow at {{property_name}}. Ref {{booking_code}}.'
  when 'HOST_STAY_BEFORE_CHECKOUT' then
    'Check out {{check_out_date}} at {{check_out_time}}. {{customer_name}} checked in {{check_in_date}} at {{check_in_time}} at {{property_name}}.'
end
where code in (
  'BOOKING_CONFIRMED_CUSTOMER',
  'STAY_TOMORROW_CUSTOMER',
  'STAY_CHECKIN_WINDOW',
  'GUEST_STAY_BEFORE_CHECKOUT',
  'BOOKING_CONFIRMED_AGENT',
  'HOST_STAY_TOMORROW',
  'HOST_STAY_BEFORE_CHECKOUT'
);

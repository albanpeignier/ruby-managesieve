#!/usr/bin/env ruby
#
#--
# Copyright (c) 2004 Andre Nathan <andre@digirati.com.br>
#
# Permission to use, copy, modify, and distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
# 
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
#++
#
# == Overview
#
# This library is a pure-ruby implementation of the MANAGESIEVE protocol, as
# specified in draft-martin-managesieve-04.txt.
#
# See the ManageSieve class for documentation and examples.
#
#--
# $Id: managesieve.rb,v 1.1 2004/12/20 17:49:51 andre Exp $
#++
#

require 'base64'
require 'socket'

class SieveAuthError < Exception; end
class SieveCommandError < Exception; end
class SieveResponseError < Exception; end

#
# ManageSieve implements MANAGESIEVE, a protocol for remote management of
# Sieve[http://www.cyrusoft.com/sieve/] scripts.
#
# The following MANAGESIEVE commands are implemented:
# * CAPABILITY
# * DELETESCRIPT
# * GETSCRIPT
# * HAVESPACE
# * LISTSCRIPTS
# * LOGOUT
# * PUTSCRIPT
# * SETACTIVE
#
# The AUTHENTICATE command is partially implemented. Currently the +LOGIN+
# and +PLAIN+ authentication mechanisms are implemented.
#
# = Example
#
#  # Create a new ManageSieve instance
#  m = ManageSieve.new(
#    :host     => 'sievehost.mydomain.com',
#    :port     => 2000,
#    :user     => 'johndoe',
#    :password => 'secret',
#    :auth     => 'PLAIN'
#  )
#
#  # List installed scripts
#  m.each_script do |name, active|
#    print name
#    print active ? " (active)\n" : "\n"
#  end
#
#  script = <<__EOF__
#  require "fileinto";
#  if header :contains ["to", "cc"] "ruby-talk@ruby-lang.org" {
#    fileinto "Ruby-talk";
#  }
#  __EOF__
#
#  # Test if there's enough space for script 'foobar'
#  puts m.have_space?('foobar', script.length)
#
#  # Upload it
#  m.put_script('foobar', script)
#
#  # Show its contents
#  puts m.get_script('foobar')
#
#  # Close the connection
#  m.logout
#
class ManageSieve
  SIEVE_PORT = 2000

  attr_reader :host, :port, :user, :euser, :capabilities, :login_mechs

  # Create a new ManageSieve instance. The +info+ parameter is a hash with the
  # following keys:
  #
  # [<i>:host</i>]      the sieve server
  # [<i>:port</i>]      the sieve port (defaults to 2000)
  # [<i>:user</i>]      the name of the user
  # [<i>:euser</i>]     the name of the effective user (defaults to +:user+)
  # [<i>:password</i>]  the password of the user
  # [<i>:auth_mech</i>] the authentication mechanism (defaults to +"ANONYMOUS"+)
  #
  def initialize(info)
    @host      = info[:host]
    @port      = info[:port] || 2000
    @user      = info[:user]
    @euser     = info[:euser] || @user
    @password  = info[:password]
    @auth_mech = info[:auth] || 'ANONYMOUS'

    @capabilities   = []
    @login_mechs    = []
    @implementation = ''
    @supports_tls   = false
    @socket = TCPSocket.new(@host, @port)

    data = get_response
    server_features(data)
    authenticate
    @password = nil
  end

  
  # Calls the given block for each script stored on the server, passing
  # its name and status as parameters. The status is either 'ACTIVE' or
  # nil.
  def each_script
    begin
      scripts = send_command('LISTSCRIPTS')
    rescue SieveCommandError => e
      raise e, "Cannot list scripts"
    end
    scripts.each { |name, status| yield(name, status) }
  end

  # Returns the contents of +script+ as a string.
  def get_script(script)
    begin
      data = send_command('GETSCRIPT', sieve_name(script))
    rescue SieveCommandError => e
      raise e, "Cannot get script: #{e}"
    end
    return data.to_s
  end

  # Uploads +script+ to the server, using +data+ as its contents.
  def put_script(script, data)
    args = sieve_name(script)
    args += ' ' + sieve_string(data) if data
    send_command('PUTSCRIPT', args)
  end

  # Deletes +script+ from the server.
  def delete_script(script)
    send_command('DELETESCRIPT', sieve_name(script))
  end

  # Sets +script+ as active.
  def set_active(script)
    send_command('SETACTIVE', sieve_name(script))
  end

  # Returns true if there is space on the server to store +script+ with
  # size +size+ and false otherwise.
  def have_space?(script, size)
    begin
      args = sieve_name(script) + ' ' + size.to_s
      send_command('HAVESPACE', args)
      return true
    rescue SieveCommandError
      return false
    end
  end

  # Returns true if the server supports TLS and false otherwise.
  def supports_tls?
    @supports_tls
  end

  # Disconnect from the server.
  def logout
    send_command('LOGOUT')
    @socket.close
  end

  private
  def authenticate # :nodoc:
    unless @login_mechs.include? @auth_mech
      raise SieveAuthError, "Server doesn't allow #{@auth_mech} authentication"
    end
    case @auth_mech
    when /PLAIN/i
      auth_plain(@euser, @user, @password)
    when /LOGIN/i
      auth_login(@user, @password)
    else
      raise SieveAuthError, "#{@auth_mech} authentication is not implemented"
    end
  end

  private
  def auth_plain(euser, user, pass) # :nodoc:
    args = [ euser, user, pass ]
    params = sieve_name('PLAIN') + ' '
    params += sieve_name(encode64(args.join(0.chr)).gsub(/\n/, ''))
    send_command('AUTHENTICATE', params)
  end

  private
  def auth_login(user, pass) # :nodoc:
    send_command('AUTHENTICATE', sieve_name('LOGIN'), false)
    send_command(sieve_name(encode64(user)).gsub(/\n/, ''), nil, false)
    send_command(sieve_name(encode64(pass)).gsub(/\n/, ''))
  end

  private
  def server_features(lines) # :nodoc:
    lines.each do |type, data|
      case type
      when 'IMPLEMENTATION'
        @implementation = data
      when 'SASL'
        @login_mechs = data.split
      when 'SIEVE'
        @capabilities = data.split
      when 'STARTTLS'
        @supports_tls = true
      end
    end
  end

  private
  def get_line # :nodoc:
    return @socket.readline.chomp
  end

  private
  def send_command(cmd, args=nil, wait_response=true) # :nodoc:
    cmd += ' ' + args if args
    begin
      @socket.send(cmd + "\r\n", 0)
      resp = get_response if wait_response
    rescue SieveResponseError => e
      raise SieveCommandError, "Command error: #{e}"
    end
    return resp
  end

  private
  def parse_each_line # :nodoc:
    loop do
      data = get_line

      # server response
      m = /(OK|NO|BYE)( \((.*)\))?( (.*))?/.match(data)
      yield :response, m.captures.values_at(0, 3) and next if m
  
      # quoted text
      m = /"([^"]*)"(\s"?([^"]*)"?)?$/.match(data)
      yield :quoted, m.captures.values_at(0,2) and next if m
      
      # literal
      m = /\{(\d+)\+?\}/.match(data)
      size = m.captures.first.to_i
      yield :literal, @socket.read(size + 2) and next if m  #  + 2 for \r\n
  
      # other
      yield :other, data
    end
  end

  private
  def get_response # :nodoc:
    response = []
    parse_each_line do |flag, data|
      case flag
      when :response
        type, error = data
        raise SieveResponseError, error unless type == 'OK'
        return response
      else
        response << data
      end
    end
  end

  private
  def sieve_name(name) # :nodoc:
    return "\"#{name}\""
  end

  private
  def sieve_string(string) # :nodoc:
    return "{#{string.length}+}\r\n#{string}"
  end

end
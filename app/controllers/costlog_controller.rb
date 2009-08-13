class CostlogController < ApplicationController
  unloadable
  
  menu_item :issues
  before_filter :find_project, :authorize, :only => [:edit, :destroy]
  before_filter :find_optional_project, :only => [:report, :details]

  verify :method => :post, :only => :destroy, :redirect_to => { :action => :details }
  
  helper :sort
  include SortHelper
  helper :issues
  include CostlogHelper

  def details
    sort_init 'spent_on', 'desc'
    sort_update 'spent_on' => 'spent_on',
                'user' => 'user_id',
                'project' => "#{Project.table_name}.name",
                'issue' => 'issue_id',
                'cost_type' => 'cost_type_id',
                'units' => 'units',
                'costs' => 'costs'
    
    cond = ARCondition.new
    if @project.nil?
      cond << Project.allowed_to_condition(User.current, :view_cost_entries)
    elsif @issue.nil?
      cond << @project.project_condition(Setting.display_subprojects_issues?)
    else
      cond << ["#{CostEntry.table_name}.issue_id = ?", @issue.id]
    end
    
    if @cost_type
      cond << ["#{CostEntry.table_name}.cost_type_id = ?", @cost_type.id ]
    end
    
    retrieve_date_range
    cond << ['spent_on BETWEEN ? AND ?', @from, @to]

    CostEntry.visible_by(User.current) do
      respond_to do |format|
        format.html {
          # Paginate results
          @entry_count = CostEntry.count(:include => :project, :conditions => cond.conditions)
          @entry_pages = Paginator.new self, @entry_count, per_page_option, params['page']
          @entries = CostEntry.find(:all, 
                                    :include => [:project, :cost_type, :user, {:issue => :tracker}],
                                    :conditions => cond.conditions,
                                    :order => sort_clause,
                                    :limit  =>  @entry_pages.items_per_page,
                                    :offset =>  @entry_pages.current.offset)
          
          render :layout => !request.xhr?
        }
        format.atom {
          entries = TimeEntry.find(:all,
                                   :include => [:project, :cost_type, :user, {:issue => :tracker}],
                                   :conditions => cond.conditions,
                                   :order => "#{CostEntry.table_name}.created_on DESC",
                                   :limit => Setting.feeds_limit.to_i)
          render_feed(entries, :title => l(:label_spent_costs))
        }
        format.csv {
          # Export all entries
          @entries = CostEntry.find(:all, 
                                    :include => [:project, :cost_type, :user, {:issue => [:tracker, :assigned_to, :priority]}],
                                    :conditions => cond.conditions,
                                    :order => sort_clause)
          send_data(entries_to_csv(@entries).read, :type => 'text/csv; header=present', :filename => 'costlog.csv')
        }
      end
    end
  end
  
  def edit
    render_403 and return if @cost_entry && !@cost_entry.editable_by?(User.current)
    if !@cost_entry
      # creates new CostEntry
      if params[:cost_entry].is_a?(Hash)
        # we have a new CostEntry in our request
        new_user = User.find_by_id(params[:cost_entry][:user_id])
        if new_user.blank? or !new_user.allowed_to?(:book_costs, @project)
          render_403 and return
        end
      end

      @cost_entry = CostEntry.new(:project => @project, :issue => @issue, :user => User.current, :spent_on => Date.today)
    end
    @cost_entry.attributes = params[:cost_entry]
    @cost_entry.cost_type ||= CostType.default
    
    if request.post? and @cost_entry.save
      flash[:notice] = l(:notice_successful_update)
      redirect_back_or_default :action => 'details', :project_id => @cost_entry.project
      return
    end
  end
  
  def destroy
    render_404 and return unless @cost_entry
    render_403 and return unless @cost_entry.editable_by?(User.current)
    @cost_entry.destroy
    flash[:notice] = l(:notice_successful_delete)
    redirect_to :back
  rescue ::ActionController::RedirectBackError
    redirect_to :action => 'details', :project_id => @cost_entry.project
  end

  def get_cost_type_unit_plural
    @cost_type = CostType.find(params[:cost_type_id]) unless params[:cost_type_id].empty?
    
    if request.xhr?
      render :partial => "cost_type_unit_plural", :locals => {:cost_type => @cost_type}
    end
  end
  
private
  def find_project
    # copied from timelog_controller.rb
    if params[:id]
      @cost_entry = CostEntry.find(params[:id])
      @project = @cost_entry.project
    elsif params[:issue_id]
      @issue = Issue.find(params[:issue_id])
      @project = @issue.project
    elsif params[:project_id]
      @project = Project.find(params[:project_id])
    else
      render_404
      return false
    end
  rescue ActiveRecord::RecordNotFound
    render_404
  end
  
  def find_optional_project
    if !params[:issue_id].blank?
      @issue = Issue.find(params[:issue_id])
      @project = @issue.project
    elsif !params[:project_id].blank?
      @project = Project.find(params[:project_id])
    end
    
    if !params[:cost_type_id].blank?
      @cost_type = CostType.find(params[:cost_type_id])
    end

    deny_access unless User.current.allowed_to?(:view_cost_entries, @project, :global => true)
  end
  
  def retrieve_date_range
    # Mostly copied from timelog_controller.rb
    @free_period = false
    @from, @to = nil, nil

    if params[:period_type] == '1' || (params[:period_type].nil? && !params[:period].nil?)
      case params[:period].to_s
      when 'today'
        @from = @to = Date.today
      when 'yesterday'
        @from = @to = Date.today - 1
      when 'current_week'
        @from = Date.today - (Date.today.cwday - 1)%7
        @to = @from + 6
      when 'last_week'
        @from = Date.today - 7 - (Date.today.cwday - 1)%7
        @to = @from + 6
      when '7_days'
        @from = Date.today - 7
        @to = Date.today
      when 'current_month'
        @from = Date.civil(Date.today.year, Date.today.month, 1)
        @to = (@from >> 1) - 1
      when 'last_month'
        @from = Date.civil(Date.today.year, Date.today.month, 1) << 1
        @to = (@from >> 1) - 1
      when '30_days'
        @from = Date.today - 30
        @to = Date.today
      when 'current_year'
        @from = Date.civil(Date.today.year, 1, 1)
        @to = Date.civil(Date.today.year, 12, 31)
      end
    elsif params[:period_type] == '2' || (params[:period_type].nil? && (!params[:from].nil? || !params[:to].nil?))
      begin; @from = params[:from].to_s.to_date unless params[:from].blank?; rescue; end
      begin; @to = params[:to].to_s.to_date unless params[:to].blank?; rescue; end
      @free_period = true
    else
      # default
    end
    
    @from, @to = @to, @from if @from && @to && @from > @to
    @from ||= (CostEntry.minimum(:spent_on, :include => :project, :conditions => Project.allowed_to_condition(User.current, :view_cost_entries)) || Date.today) - 1
    @to   ||= (CostEntry.maximum(:spent_on, :include => :project, :conditions => Project.allowed_to_condition(User.current, :view_cost_entries)) || Date.today)
  end
  
  
end
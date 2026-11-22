using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Hally.Infrastructure.Persistence.Migrations
{
    /// <inheritdoc />
    public partial class EventRepeat : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<string>(
                name: "repeat",
                table: "events",
                type: "character varying(16)",
                maxLength: 16,
                nullable: false,
                defaultValue: "None");

            migrationBuilder.AddColumn<DateOnly>(
                name: "repeat_until",
                table: "events",
                type: "date",
                nullable: true);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropColumn(
                name: "repeat",
                table: "events");

            migrationBuilder.DropColumn(
                name: "repeat_until",
                table: "events");
        }
    }
}
